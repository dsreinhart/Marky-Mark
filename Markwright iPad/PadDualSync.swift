//
//  PadDualSync.swift
//  Markwright iPad
//
//  Keeps Dual's two panes (Raw and Formatted) scrolled to the same place. The panes have different
//  heights, so the position is translated block by block through the formatted editor's source map:
//  the top of a block in one pane lines up with the top of the same block in the other, and both
//  reach their ends together. Whichever pane the person scrolls or types in leads. A port of the
//  Mac's DualPaneSync to UIKit.
//

import UIKit

@MainActor
final class PadDualSync {
    weak var raw: UITextView?
    weak var rich: PadRichCoordinator?
    /// On only while both panes are showing.
    var isEnabled = false {
        didSet { if isEnabled && !oldValue { scheduleResync() } }
    }
    /// The pane whose scroll position the other one follows.
    private(set) var driver: PadEditorController.Pane = .raw
    /// True while this object is moving a pane itself.
    private var isApplying = false
    private var resyncScheduled = false

    private var richView: UITextView? { rich?.textView }

    private func view(_ pane: PadEditorController.Pane) -> UITextView? {
        pane == .raw ? raw : richView
    }

    // MARK: Events

    func setDriver(_ pane: PadEditorController.Pane) { driver = pane }

    func paneWillBeginDragging(_ pane: PadEditorController.Pane) { driver = pane }

    func paneDidScroll(_ pane: PadEditorController.Pane) {
        guard isEnabled, !isApplying, let view = view(pane) else { return }
        if view.isTracking || view.isDragging || view.isDecelerating { driver = pane }
        guard pane == driver else { return }
        follow(from: pane)
    }

    /// A pane changed height (images arriving, rotation): what is on screen may have moved.
    func contentHeightChanged() {
        guard isEnabled, !isApplying else { return }
        scheduleResync()
    }

    private func scheduleResync() {
        guard !resyncScheduled else { return }
        resyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resyncScheduled = false
            self.resync()
        }
    }

    /// Moves the following pane to match the driver.
    func resync() {
        guard isEnabled else { return }
        follow(from: driver)
    }

    // MARK: Following

    private func follow(from pane: PadEditorController.Pane) {
        guard let raw, let richView, let map = rich?.sourceMap else { return }
        let anchors = Self.anchors(raw: raw, rich: richView, map: map)
        let source = pane == .raw ? raw : richView
        let target = pane == .raw ? richView : raw
        let y = Self.visibleTop(source)
        let mapped = pane == .raw
            ? Self.interpolate(y, from: anchors.map(\.raw), to: anchors.map(\.rich))
            : Self.interpolate(y, from: anchors.map(\.rich), to: anchors.map(\.raw))
        let offset = min(max(mapped, 0), Self.maxVisibleTop(target)) - target.adjustedContentInset.top
        guard abs(offset - target.contentOffset.y) >= 0.5 else { return }
        isApplying = true
        target.setContentOffset(CGPoint(x: target.contentOffset.x, y: offset), animated: false)
        isApplying = false
    }

    // MARK: Geometry

    /// Content y at the top of the visible area, counted from the top of the text view's content.
    static func visibleTop(_ view: UITextView) -> CGFloat {
        view.contentOffset.y + view.adjustedContentInset.top
    }

    static func maxVisibleTop(_ view: UITextView) -> CGFloat {
        let insets = view.adjustedContentInset
        return max(view.contentSize.height + insets.bottom + insets.top - view.bounds.height, 0)
    }

    /// The visible top that puts a character's line at the top of a pane.
    static func scrollY(of location: Int, in view: UITextView) -> CGFloat {
        let layoutManager = view.layoutManager
        let characters = view.textStorage.length
        guard characters > 0, layoutManager.numberOfGlyphs > 0 else { return 0 }
        let glyph = min(layoutManager.glyphIndexForCharacter(at: min(max(location, 0), characters - 1)),
                        layoutManager.numberOfGlyphs - 1)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.textContainerInset.top
    }

    /// Visible tops that correspond, from the top to the end of the document.
    static func anchors(raw: UITextView, rich: UITextView, map: SourceMap) -> [(raw: CGFloat, rich: CGFloat)] {
        let rawMax = maxVisibleTop(raw)
        let richMax = maxVisibleTop(rich)
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
