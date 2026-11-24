//
//  PadCommands.swift
//  Markwright iPad
//
//  The menu bar and hardware-keyboard shortcuts, the same keys as on the Mac. They act on the
//  window in front through its focused values.
//

import SwiftUI

struct PadCommands: Commands {
    @FocusedValue(\.padWindow) private var window
    @FocusedValue(\.padDocument) private var document

    private var controller: PadEditorController? { document?.controller }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Sheet") { window?.newSheet() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(window == nil)
            Button("Quick Open\u{2026}") { window?.quickOpen() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(window == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { document?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(document == nil)
            Button("Save a Version") { document?.saveVersion() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(document == nil)
            Divider()
            Button("Export Preview\u{2026}") { document?.exportPreview() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(document == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { document?.print() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(document == nil)
        }

        CommandMenu("Format") {
            formatItems.disabled(document == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Show or Hide Library") { window?.toggleLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(window == nil)
            Button("Show or Hide Dashboard") { document?.toggleDashboard() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(document == nil)
            Button("Typewriter Scrolling") { document?.toggleTypewriter() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(document == nil)
            Button("Composition Mode") { document?.toggleComposition() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(document == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { document?.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(document == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Markwright Help") { document?.showHelp() }
                .keyboardShortcut("?", modifiers: .command)
                .disabled(document == nil)
        }
    }

    @ViewBuilder
    private var formatItems: some View {
        Group {
            Button("Bold") { controller?.applyInline(.mmBold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { controller?.applyInline(.mmItalic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Strikethrough") { controller?.applyInline(.mmStrike) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Inline Code") { controller?.applyInline(.mmCode) }
                .keyboardShortcut("e", modifiers: .command)
            Button("Highlight") { controller?.applyInline(.mmHighlight) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Link\u{2026}") { controller?.requestLink() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Footnote") { controller?.addFootnote() }
                .keyboardShortcut("f", modifiers: [.command, .shift, .option])
        }
        Divider()
        Group {
            Button("Paragraph") { controller?.applyHeading(0) }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { controller?.applyHeading(level) }
                    .keyboardShortcut(KeyEquivalent(Character(String(level))), modifiers: .command)
            }
        }
        Divider()
        Group {
            Button("Bulleted List") { controller?.applyBulletList() }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { controller?.applyNumberedList() }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Task List") { controller?.applyTaskList() }
                .keyboardShortcut("9", modifiers: [.command, .shift])
            Button("Blockquote") { controller?.applyQuote() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Code Block") { controller?.applyCodeBlock() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Comment") { controller?.applyComment() }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
        Divider()
        Group {
            Button("Indent") { controller?.indent(forward: true) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { controller?.indent(forward: false) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Fold or Unfold Section") { controller?.toggleFold() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Unfold All Sections") { controller?.unfoldAll() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
        }
    }
}
