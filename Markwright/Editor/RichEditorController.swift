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
    /// The raw editor's text view when raw mode is showing.
    @ObservationIgnored weak var rawTextView: NSTextView? = nil
    /// Set by whichever editor is on screen; moves the cursor to the nth heading.
    @ObservationIgnored var jumpToHeading: ((Int) -> Void)? = nil
    /// Set by whichever editor is on screen; returns the markdown before and after the cursor's paragraph.
    @ObservationIgnored var splitAtCursor: (() -> (String, String)?)? = nil

    /// True while an editor is on screen (menu commands are enabled).
    var isActive = false
    var state = FormatState()
    /// The document's file, for resolving wiki links relative to it.
    var documentURL: URL? = nil

    var showLinkPopover = false
    var showImagePopover = false
    var showTablePopover = false

    private var raw: NSTextView? { coordinator == nil ? rawTextView : nil }
    /// Whichever text view is on screen.
    var activeTextView: NSTextView? { coordinator?.textView ?? rawTextView }

    /// Recomputes `isActive` after an editor attaches or detaches. SwiftUI can create the
    /// incoming editor before it dismantles the outgoing one, so neither may just set false.
    func refreshActive() { isActive = coordinator != nil || rawTextView != nil }

    /// Selects the next occurrence of `needle` after the cursor (wrapping), scrolls to it and flashes it.
    func jump(toText needle: String) {
        guard let textView = activeTextView, !needle.isEmpty else { return }
        let ns = textView.string as NSString
        let start = min(NSMaxRange(textView.selectedRange), ns.length)
        var found = ns.range(of: needle, options: [], range: NSRange(location: start, length: ns.length - start))
        if found.location == NSNotFound { found = ns.range(of: needle) }
        guard found.location != NSNotFound else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
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
    func toggleFold() { coordinator?.toggleFold() }
    func unfoldAll() { coordinator?.unfoldAll() }

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
    func increaseIndent() { coordinator?.changeIndent(by: 1) }
    func decreaseIndent() { coordinator?.changeIndent(by: -1) }

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
