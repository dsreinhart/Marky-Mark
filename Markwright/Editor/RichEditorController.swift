//
//  RichEditorController.swift
//  Markwright
//
//  Bridge between SwiftUI (toolbar, menu commands) and whichever editor is on
//  screen: the rendered editor's coordinator, or the raw editor's text view
//  (where commands insert Markdown syntax instead).
//

import SwiftUI
import AppKit

struct FormatState: Equatable {
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var highlight = false
    var hasLink = false
    /// The section at the cursor is folded.
    var folded = false
    var blockKind: BlockKind = .paragraph
    var indent = 0
    var hasSelection = false
}

@MainActor
@Observable
final class RichEditorController {
    @ObservationIgnored weak var coordinator: RichMarkdownEditorView.Coordinator? = nil
    /// The raw editor's text view when raw or dual mode is showing.
    @ObservationIgnored weak var rawTextView: NSTextView? = nil
    /// The raw editor's own commands; the formatted editor's come from its coordinator.
    @ObservationIgnored weak var rawCoordinator: MarkdownEditorView.Coordinator? = nil
    /// Keeps the panes of dual mode scrolled together.
    @ObservationIgnored let paneSync = DualPaneSync()
    /// Where the editors were when the mode changed, until the new layout has been restored to it.
    @ObservationIgnored private(set) var pendingPosition: EditorPosition? = nil

    /// Moves the cursor to the nth heading in the pane in use.
    var jumpToHeading: ((Int) -> Void)? {
        if rawHasFocusNow, let rawCoordinator { return { [weak rawCoordinator] in rawCoordinator?.jumpToHeading($0) } }
        if let coordinator { return { [weak coordinator] in coordinator?.jumpToHeading($0) } }
        if let rawCoordinator { return { [weak rawCoordinator] in rawCoordinator?.jumpToHeading($0) } }
        return nil
    }

    /// The markdown before and after the cursor's paragraph, in the pane in use.
    var splitAtCursor: (() -> (String, String)?)? {
        if rawHasFocusNow, let rawCoordinator { return { [weak rawCoordinator] in rawCoordinator?.splitAtCursor() } }
        if let coordinator { return { [weak coordinator] in coordinator?.splitAtCursor() } }
        if let rawCoordinator { return { [weak rawCoordinator] in rawCoordinator?.splitAtCursor() } }
        return nil
    }

    /// True while an editor is on screen (menu commands are enabled).
    var isActive = false
    /// The cursor is in the raw pane, so the toolbar has no formatting to show.
    var rawHasFocus = false
    var state = FormatState()
    /// The document's file, for resolving wiki links relative to it.
    var documentURL: URL? = nil

    var showLinkPopover = false
    var showImagePopover = false
    var showTablePopover = false

    /// The raw editor when commands should insert Markdown syntax. Asking also brings the pane about
    /// to be edited up to date, since a pane out of focus catches up only after a short pause.
    private var raw: NSTextView? {
        if rawHasFocusNow {
            rawCoordinator?.flushPendingText()
            return rawTextView
        }
        coordinator?.flushPendingText()
        return nil
    }

    /// Both panes are showing.
    var isDual: Bool { coordinator != nil && rawTextView != nil }

    /// Raw mode, or the raw pane of dual mode holding the cursor.
    private var rawHasFocusNow: Bool {
        guard let rawTextView else { return false }
        return coordinator == nil || rawTextView.window?.firstResponder === rawTextView
    }

    /// The text view in use.
    var activeTextView: NSTextView? { rawHasFocusNow ? rawTextView : (coordinator?.textView ?? rawTextView) }

    /// Recomputes state after an editor attaches or detaches. SwiftUI can create the
    /// incoming editor before it dismantles the outgoing one, so neither may just set false.
    func refreshActive() {
        isActive = coordinator != nil || rawTextView != nil
        rawHasFocus = rawHasFocusNow
        paneSync.link(raw: rawTextView, rich: coordinator?.textView) { [weak self] in self?.coordinator?.sourceMap }
        let dual = isDual
        let handler: ((NSTextView, NSRange) -> Void)? = dual ? { [weak self] view, range in self?.revealInBothPanes(from: view, range: range) } : nil
        (rawTextView as? MarkwrightTextView)?.revealHandler = handler
        (coordinator?.textView as MarkwrightTextView?)?.revealHandler = handler
    }

    /// A pane took the cursor: it leads scrolling and has to be up to date before it is edited.
    func paneDidTakeFocus(_ view: NSTextView) {
        if view === rawTextView {
            rawCoordinator?.flushPendingText()
        } else {
            coordinator?.flushPendingText()
        }
        guard isDual else { return }
        paneSync.setDriver(view)
        rawHasFocus = rawHasFocusNow
        if rawHasFocus {
            state = FormatState()
        } else {
            coordinator?.refreshState()
        }
        coordinator?.applyBehaviors()
        rawCoordinator?.applyBehaviors()
    }

    func flushPendingText() {
        rawCoordinator?.flushPendingText()
        coordinator?.flushPendingText()
    }

    // MARK: - Keeping the place across modes

    /// A place in the document, in source terms so that it survives a change of layout.
    struct EditorPosition: Equatable {
        /// Source position at the top of the view; nil when scrolled to the very top.
        var top: Int?
        var selection: NSRange
        var hadFocus: Bool
    }

    /// The place currently shown by a pane.
    func position(of view: NSTextView) -> EditorPosition? {
        guard let layoutManager = view.layoutManager, let container = view.textContainer,
              let clip = view.enclosingScrollView?.contentView else { return nil }
        let isRich = view === coordinator?.textView
        let map = isRich ? coordinator?.sourceMap : nil
        let selection: NSRange
        var top: Int? = nil

        func toSource(_ location: Int) -> Int {
            guard isRich, let map else { return location }
            return map.rawLocation(forRendered: location, raw: sourceText as NSString, rendered: view.string as NSString)
        }
        if isRich, let map {
            selection = map.rawRange(forRendered: view.selectedRange, raw: sourceText as NSString, rendered: view.string as NSString)
        } else {
            selection = view.selectedRange
        }
        let y = clip.bounds.minY
        if y > 1, layoutManager.numberOfGlyphs > 0 {
            var fraction: CGFloat = 0
            let point = NSPoint(x: 8, y: y - view.textContainerOrigin.y + 1)
            let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            top = toSource(layoutManager.characterIndexForGlyph(at: glyph))
        }
        return EditorPosition(top: top, selection: selection, hadFocus: view.window?.firstResponder === view)
    }

    /// The Markdown the formatted pane currently shows.
    private var sourceText: String { coordinator?.lastKnownText ?? rawTextView?.string ?? "" }

    /// Call just before an editor appears or goes away, while the outgoing layout is still intact.
    /// The first call of a mode change records the place; the restore runs once the change is done.
    func editorsWillChange() {
        guard pendingPosition == nil else { return }
        flushPendingText()
        guard let view = rawHasFocusNow ? rawTextView : (coordinator?.textView ?? rawTextView),
              let position = position(of: view) else { return }
        pendingPosition = position
        scheduleRestore(attempt: 0)
    }

    private func scheduleRestore(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.02)) { [weak self] in
            guard let self else { return }
            if self.restorePosition() { return }
            if attempt < 40 {
                self.scheduleRestore(attempt: attempt + 1)
            } else {
                self.finishRestore()
            }
        }
    }

    /// Puts the panes back on the recorded place. False while they have not been laid out yet.
    @discardableResult
    func restorePosition() -> Bool {
        guard let position = pendingPosition else { return true }
        let views = [rawTextView, coordinator?.textView].compactMap { $0 }
        guard !views.isEmpty else {
            finishRestore()
            return true
        }
        for view in views {
            guard let scrollView = view.enclosingScrollView, scrollView.window != nil,
                  scrollView.contentView.bounds.width > 50 else { return false }
        }
        views.first?.window?.layoutIfNeeded()
        for view in views {
            if let layoutManager = view.layoutManager, let container = view.textContainer {
                layoutManager.ensureLayout(for: container)
            }
        }

        // Selection first: typewriter scrolling reacts to it, and the scroll below must have the last word.
        if let rawTextView {
            rawTextView.setSelectedRange(Self.clamp(position.selection, to: (rawTextView.string as NSString).length))
        }
        if let rich = coordinator?.textView, let map = coordinator?.sourceMap {
            let range = map.renderedRange(forRaw: position.selection, raw: sourceText as NSString, rendered: rich.string as NSString)
            rich.setSelectedRange(Self.clamp(range, to: (rich.string as NSString).length))
        }

        let lead = (rawHasFocusNow ? rawTextView : coordinator?.textView) ?? views[0]
        if position.hadFocus { lead.window?.makeFirstResponder(lead) }
        paneSync.setDriver(lead)
        var y: CGFloat = 0
        if let top = position.top {
            if lead === rawTextView {
                y = DualPaneSync.scrollY(of: top, in: lead)
            } else if let map = coordinator?.sourceMap {
                let location = map.renderedLocation(forRaw: top, raw: sourceText as NSString, rendered: lead.string as NSString)
                y = DualPaneSync.scrollY(of: location, in: lead)
            }
        }
        if let scrollView = lead.enclosingScrollView {
            let clip = scrollView.contentView
            let target = min(max(y, 0), DualPaneSync.maxScrollY(of: lead))
            paneSync.withoutFollowing {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        paneSync.resync()
        finishRestore()
        return true
    }

    private func finishRestore() {
        pendingPosition = nil
        rawTextView?.enclosingScrollView?.alphaValue = 1
        coordinator?.textView?.enclosingScrollView?.alphaValue = 1
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    // MARK: - Revealing in both panes

    /// A footnote jump or similar in one pane of dual mode: show the same place in the other.
    private func revealInBothPanes(from view: NSTextView, range: NSRange) {
        guard let rawTextView, let coordinator, let rich = coordinator.textView else { return }
        let map = coordinator.sourceMap
        if view === rawTextView {
            let mapped = map.renderedRange(forRaw: range, raw: rawTextView.string as NSString, rendered: rich.string as NSString)
            reveal(rawRange: range, richRange: coordinator.visibleRange(for: mapped), lead: rawTextView)
        } else {
            let mapped = map.rawRange(forRendered: range, raw: rawTextView.string as NSString, rendered: rich.string as NSString)
            reveal(rawRange: mapped, richRange: range, lead: rich)
        }
    }

    /// Selects and flashes a place in both panes, leaving the cursor in `lead`.
    private func reveal(rawRange: NSRange, richRange: NSRange, lead: NSTextView) {
        guard let rawTextView, let rich = coordinator?.textView else { return }
        lead.window?.makeFirstResponder(lead)
        paneSync.setDriver(lead)
        rawTextView.setSelectedRange(rawRange)
        rich.setSelectedRange(richRange)
        lead.scrollRangeToVisible(lead === rawTextView ? rawRange : richRange)
        paneSync.resync()
        // Following lines up the tops of blocks, which can leave the place just out of view.
        let other = lead === rawTextView ? rich : rawTextView
        paneSync.withoutFollowing { other.scrollRangeToVisible(lead === rawTextView ? richRange : rawRange) }
        rawTextView.showFindIndicator(for: rawRange)
        rich.showFindIndicator(for: richRange)
    }

    /// Selects the next occurrence of `needle` after the cursor (wrapping), scrolls to it and flashes it.
    /// Selects and briefly highlights `needle`: the next occurrence after the cursor (wrapping),
    /// or the first one in the document when `fromStart` is set.
    func jump(toText needle: String, fromStart: Bool = false, backwards: Bool = false,
              options: NSString.CompareOptions = []) {
        flushPendingText()
        // Dual mode searches the source, which is what the sidebar counts, and shows it in both panes.
        guard let textView = isDual ? rawTextView : activeTextView, !needle.isEmpty else { return }
        let ns = textView.string as NSString
        var selection = textView.selectedRange
        let richLeads = isDual && !rawHasFocusNow && coordinator?.textView?.window?.firstResponder === coordinator?.textView
        if richLeads, let rich = coordinator?.textView, let map = coordinator?.sourceMap {
            selection = map.rawRange(forRendered: rich.selectedRange, raw: ns, rendered: rich.string as NSString)
        }
        var found: NSRange
        if backwards {
            let end = min(selection.location, ns.length)
            found = ns.range(of: needle, options: options.union(.backwards), range: NSRange(location: 0, length: end))
            if found.location == NSNotFound { found = ns.range(of: needle, options: options.union(.backwards)) }
        } else {
            let start = fromStart ? 0 : min(NSMaxRange(selection), ns.length)
            found = ns.range(of: needle, options: options, range: NSRange(location: start, length: ns.length - start))
            if found.location == NSNotFound { found = ns.range(of: needle, options: options) }
        }
        guard found.location != NSNotFound else { return }
        if isDual, let coordinator, let rich = coordinator.textView {
            let match = coordinator.sourceMap.renderedMatch(forRaw: found, needle: needle, options: options,
                                                            raw: ns, rendered: rich.string as NSString)
            reveal(rawRange: found, richRange: match, lead: richLeads ? rich : textView)
        } else {
            EditorBehaviors.reveal(textView, range: found)
        }
    }

    /// Number of occurrences of `needle` in `text`, as the library search counts them.
    static func matchCount(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        let ns = text as NSString
        var count = 0
        var location = 0
        while location < ns.length {
            let r = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                             range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            count += 1
            location = NSMaxRange(r)
        }
        return count
    }

    // MARK: - Inline formatting

    func toggleBold() {
        if let raw { RawMarkup.wrap(raw, prefix: "**", suffix: "**", placeholder: "bold") } else { coordinator?.toggleInline(.mmBold) }
    }
    func toggleItalic() {
        if let raw { RawMarkup.wrap(raw, prefix: "*", suffix: "*", placeholder: "italic") } else { coordinator?.toggleInline(.mmItalic) }
    }
    func toggleStrikethrough() {
        if let raw { RawMarkup.wrap(raw, prefix: "~~", suffix: "~~", placeholder: "struck") } else { coordinator?.toggleInline(.mmStrike) }
    }
    func toggleInlineCode() {
        if let raw { RawMarkup.wrap(raw, prefix: "`", suffix: "`", placeholder: "code") } else { coordinator?.toggleInline(.mmCode) }
    }
    func toggleHighlight() {
        if let raw { RawMarkup.wrap(raw, prefix: "==", suffix: "==", placeholder: "highlight") } else { coordinator?.toggleInline(.mmHighlight) }
    }
    func insertFootnote() {
        if let raw { RawMarkup.insertFootnote(raw) } else { coordinator?.insertFootnote() }
    }
    func toggleFold() { if raw == nil { coordinator?.toggleFold() } }
    func unfoldAll() { if raw == nil { coordinator?.unfoldAll() } }

    func requestLink() {
        guard isActive else { return }
        if let raw {
            RawMarkup.wrap(raw, prefix: "[", suffix: "](https://)", placeholder: "link text")
        } else if state.hasLink {
            coordinator?.applyLink(nil)
        } else {
            showLinkPopover = true
        }
    }

    func requestImage() {
        guard isActive else { return }
        if let raw {
            RawMarkup.insertBlock(raw, "![alt text](image.png)", selectingPlaceholder: "image.png")
        } else {
            showImagePopover = true
        }
    }

    func requestTable() {
        guard isActive else { return }
        if let raw {
            RawMarkup.insertBlock(raw, "| Header 1 | Header 2 |\n| --- | --- |\n| Cell | Cell |", selectingPlaceholder: "Header 1")
        } else {
            showTablePopover = true
        }
    }

    func insertLink(url: String, text: String) {
        coordinator?.insertLink(url: url, text: text)
        focusEditor()
    }

    func insertImage(alt: String, source: String) {
        if let raw {
            RawMarkup.insertBlock(raw, "![\(alt)](\(source))")
        } else {
            coordinator?.insertImage(alt: alt, source: source)
        }
        focusEditor()
    }

    func insertTable(rows: Int, columns: Int) {
        coordinator?.insertTable(rows: rows, columns: columns)
        focusEditor()
    }

    // MARK: - Blocks

    func setBlock(_ kind: BlockKind) { coordinator?.applyBlock(kind) }

    func setHeading(_ level: Int?) {
        if let raw {
            RawMarkup.setHeading(raw, level: level ?? 0)
        } else if let level {
            coordinator?.applyBlock(.heading(level: level), toggle: false)
        } else {
            coordinator?.applyBlock(.paragraph, toggle: false)
        }
    }
    func toggleBulletList() {
        if let raw { RawMarkup.togglePrefix(raw, "- ", alternatives: ["* ", "+ ", "- [ ] ", "- [x] ", "1. "]) } else { coordinator?.applyBlock(.bullet) }
    }
    func toggleOrderedList() {
        if let raw { RawMarkup.toggleNumbered(raw) } else { coordinator?.applyBlock(.ordered) }
    }
    func toggleTaskList() {
        if let raw { RawMarkup.togglePrefix(raw, "- [ ] ", alternatives: ["- [x] ", "- ", "* ", "+ ", "1. "]) } else { coordinator?.applyBlock(.task(checked: false)) }
    }
    func toggleBlockquote() {
        if let raw { RawMarkup.togglePrefix(raw, "> ") } else { coordinator?.applyBlock(.blockquote) }
    }
    func toggleCodeBlock() {
        if let raw { RawMarkup.insertBlock(raw, "```\ncode\n```", selectingPlaceholder: "code") } else { coordinator?.applyBlock(.codeBlock(language: "")) }
    }
    func toggleComment() {
        if let raw { RawMarkup.insertBlock(raw, "<!-- note -->", selectingPlaceholder: "note") } else { coordinator?.applyBlock(.comment) }
    }
    func insertHorizontalRule() {
        if let raw { RawMarkup.insertBlock(raw, "---") } else { coordinator?.insertHorizontalRule() }
    }
    func increaseIndent() { if raw == nil { coordinator?.changeIndent(by: 1) } }
    func decreaseIndent() { if raw == nil { coordinator?.changeIndent(by: -1) } }

    func focusEditor() {
        if let raw { raw.window?.makeFirstResponder(raw) } else { coordinator?.focus() }
    }
}

// MARK: - Focused value for menu commands

struct RichEditorControllerKey: FocusedValueKey {
    typealias Value = RichEditorController
}

extension FocusedValues {
    var richEditorController: RichEditorController? {
        get { self[RichEditorControllerKey.self] }
        set { self[RichEditorControllerKey.self] = newValue }
    }
}
