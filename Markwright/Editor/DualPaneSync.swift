//
//  DualPaneSync.swift
//  Markwright
//
//  Keeps the two panes of Dual mode scrolled to the same place. The panes have different heights,
//  so the scroll position is translated block by block: the top of a block in one pane lines up
//  with the top of the same block in the other, and both reach their ends together.
//

import AppKit

@MainActor
final class DualPaneSync: NSObject {
    private weak var raw: NSTextView?
    private weak var rich: NSTextView?
    private var map: () -> SourceMap? = { nil }
    /// The pane whose scroll position the other one follows.
    private(set) weak var driver: NSTextView?
    /// True while this object is moving a pane itself.
    private var isApplying = false
    private var resyncScheduled = false

    var isLinked: Bool { raw != nil && rich != nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Links two panes, or unlinks when either is nil.
    func link(raw: NSTextView?, rich: NSTextView?, map: @escaping () -> SourceMap?) {
        guard raw !== self.raw || rich !== self.rich else { return }
        NotificationCenter.default.removeObserver(self)
        self.raw = raw
        self.rich = rich
        self.map = map
        driver = nil
        guard let raw, let rich else { return }
        for view in [raw, rich] {
            guard let scrollView = view.enclosingScrollView else { continue }
            scrollView.contentView.postsBoundsChangedNotifications = true
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted(_:)),
                                                   name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(frameChanged(_:)),
                                                   name: NSView.frameDidChangeNotification, object: view)
        }
    }

    func setDriver(_ view: NSTextView?) { driver = view }

    /// Moves a pane without the other one following.
    func withoutFollowing(_ body: () -> Void) {
        let wasApplying = isApplying
        isApplying = true
        body()
        isApplying = wasApplying
    }

    /// Moves the following pane to match the driver.
    func resync() {
        guard let raw, let rich else { return }
        let source = driver ?? raw
        follow(source, into: source === raw ? rich : raw)
    }

    // MARK: Notifications

    @objc private func liveScrollStarted(_ note: Notification) {
        guard let scrollView = note.object as? NSScrollView else { return }
        if raw?.enclosingScrollView === scrollView { driver = raw }
        if rich?.enclosingScrollView === scrollView { driver = rich }
    }

    @objc private func boundsChanged(_ note: Notification) {
        guard !isApplying, let raw, let rich, let clip = note.object as? NSClipView else { return }
        let moved = raw.enclosingScrollView?.contentView === clip ? raw : rich
        if isUserScroll(of: moved) { driver = moved }
        guard moved === (driver ?? raw) else { return }
        follow(moved, into: moved === raw ? rich : raw)
    }

    /// The pane changing height (images arriving, window resized) moves what is on screen.
    @objc private func frameChanged(_ note: Notification) {
        guard !isApplying, !resyncScheduled else { return }
        resyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resyncScheduled = false
            self.resync()
        }
    }

    private func isUserScroll(of view: NSTextView) -> Bool {
        if view.window?.firstResponder === view { return true }
        switch NSApp?.currentEvent?.type {
        case .scrollWheel, .leftMouseDown, .leftMouseDragged: return true
        default: return false
        }
    }

    private func follow(_ source: NSTextView, into target: NSTextView) {
        guard let raw, let rich, let map = map(),
              let sourceClip = source.enclosingScrollView?.contentView,
              let targetScroll = target.enclosingScrollView else { return }
        let anchors = Self.anchors(raw: raw, rich: rich, map: map)
        let y = sourceClip.bounds.minY
        let mapped = source === raw
            ? Self.interpolate(y, from: anchors.map(\.raw), to: anchors.map(\.rich))
            : Self.interpolate(y, from: anchors.map(\.rich), to: anchors.map(\.raw))
        let clip = targetScroll.contentView
        guard abs(clip.bounds.minY - mapped) > 0.5 else { return }
        withoutFollowing {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: mapped))
            targetScroll.reflectScrolledClipView(clip)
        }
    }

    // MARK: Geometry

    /// The scroll offset that puts a character's line at the top of a pane.
    static func scrollY(of location: Int, in view: NSTextView) -> CGFloat {
        guard let layoutManager = view.layoutManager, layoutManager.numberOfGlyphs > 0 else { return 0 }
        let characters = view.textStorage?.length ?? 0
        guard characters > 0 else { return 0 }
        let glyph = min(layoutManager.glyphIndexForCharacter(at: min(max(location, 0), characters - 1)),
                        layoutManager.numberOfGlyphs - 1)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.textContainerOrigin.y
    }

    static func maxScrollY(of view: NSTextView) -> CGFloat {
        guard let clip = view.enclosingScrollView?.contentView else { return 0 }
        return max(view.frame.height - clip.bounds.height, 0)
    }

    /// Scroll offsets that correspond, from the top to the end of the document.
    static func anchors(raw: NSTextView, rich: NSTextView, map: SourceMap) -> [(raw: CGFloat, rich: CGFloat)] {
        let rawMax = maxScrollY(of: raw)
        let richMax = maxScrollY(of: rich)
        var result: [(raw: CGFloat, rich: CGFloat)] = [(0, 0)]
        for entry in map.entries {
            let rawY = scrollY(of: entry.raw.location, in: raw)
            let richY = scrollY(of: entry.rendered.location, in: rich)
            guard let last = result.last, rawY > last.raw, richY > last.rich, rawY < rawMax, richY < richMax else { continue }
            result.append((rawY, richY))
        }
        if rawMax > 0 || richMax > 0 { result.append((rawMax, richMax)) }
        return result
    }

    /// Straight-line interpolation between sorted anchor points.
    static func interpolate(_ value: CGFloat, from: [CGFloat], to: [CGFloat]) -> CGFloat {
        guard let first = from.first, let last = from.last, let firstTo = to.first, let lastTo = to.last else { return 0 }
        if value <= first { return firstTo }
        if value >= last { return lastTo }
        var low = 0
        var high = from.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if from[middle] <= value { low = middle } else { high = middle }
        }
        let span = from[high] - from[low]
        guard span > 0 else { return to[low] }
        return to[low] + (value - from[low]) / span * (to[high] - to[low])
    }
}
