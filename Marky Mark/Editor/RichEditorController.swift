//
//  RichEditorController.swift
//  Marky Mark
//
//  Bridge between SwiftUI (toolbar, menu commands) and the rendered editor's
//  coordinator.
//

import SwiftUI

struct FormatState: Equatable {
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var hasLink = false
    var blockKind: BlockKind = .paragraph
    var indent = 0
    var hasSelection = false
}

@MainActor
@Observable
final class RichEditorController {
    @ObservationIgnored weak var coordinator: RichMarkdownEditorView.Coordinator? = nil
    /// Set by whichever editor is on screen; moves the cursor to the nth heading.
    @ObservationIgnored var jumpToHeading: ((Int) -> Void)? = nil
    /// Set by whichever editor is on screen; returns the markdown before and after the cursor's paragraph.
    @ObservationIgnored var splitAtCursor: (() -> (String, String)?)? = nil

    /// True while a rendered editor is on screen (menu commands are enabled).
    var isActive = false
    var state = FormatState()

    var showLinkPopover = false
    var showImagePopover = false
    var showTablePopover = false

    // MARK: - Inline formatting

    func toggleBold() { coordinator?.toggleInline(.mmBold) }
    func toggleItalic() { coordinator?.toggleInline(.mmItalic) }
    func toggleStrikethrough() { coordinator?.toggleInline(.mmStrike) }
    func toggleInlineCode() { coordinator?.toggleInline(.mmCode) }

    func requestLink() {
        guard isActive else { return }
        if state.hasLink {
            coordinator?.applyLink(nil)
        } else {
            showLinkPopover = true
        }
    }

    func requestImage() {
        guard isActive else { return }
        showImagePopover = true
    }

    func requestTable() {
        guard isActive else { return }
        showTablePopover = true
    }

    func insertLink(url: String, text: String) {
        coordinator?.insertLink(url: url, text: text)
        focusEditor()
    }

    func insertImage(alt: String, source: String) {
        coordinator?.insertImage(alt: alt, source: source)
        focusEditor()
    }

    func insertTable(rows: Int, columns: Int) {
        coordinator?.insertTable(rows: rows, columns: columns)
        focusEditor()
    }

    // MARK: - Blocks

    func setBlock(_ kind: BlockKind) { coordinator?.applyBlock(kind) }
    func setHeading(_ level: Int?) {
        if let level {
            coordinator?.applyBlock(.heading(level: level), toggle: false)
        } else {
            coordinator?.applyBlock(.paragraph, toggle: false)
        }
    }
    func toggleBulletList() { coordinator?.applyBlock(.bullet) }
    func toggleOrderedList() { coordinator?.applyBlock(.ordered) }
    func toggleTaskList() { coordinator?.applyBlock(.task(checked: false)) }
    func toggleBlockquote() { coordinator?.applyBlock(.blockquote) }
    func toggleCodeBlock() { coordinator?.applyBlock(.codeBlock(language: "")) }
    func toggleComment() { coordinator?.applyBlock(.comment) }
    func insertHorizontalRule() { coordinator?.insertHorizontalRule() }
    func increaseIndent() { coordinator?.changeIndent(by: 1) }
    func decreaseIndent() { coordinator?.changeIndent(by: -1) }

    func focusEditor() {
        coordinator?.focus()
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
