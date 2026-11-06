//
//  MarkwrightApp.swift
//  Markwright
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI

@main
struct MarkwrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(for: UUID.self) { $documentID in
            DocumentWindowView(documentID: $documentID)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            FileCommands()
            EditCommands()
            FormatCommands()
            ViewCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Intercept kAEOpenDocuments BEFORE SwiftUI registers its own handler so we control
        // which window a file opens in.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    /// Handles kAEOpenDocuments Apple Events directly: each file opens in its own tab.
    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let store = DocumentStore.shared
        for i in 1...max(directObject.numberOfItems, 1) {
            guard let descriptor = directObject.atIndex(i) else { continue }
            let url: URL?
            if let urlDescriptor = descriptor.coerce(toDescriptorType: typeFileURL),
               let urlString = String(data: urlDescriptor.data, encoding: .utf8) {
                url = URL(string: urlString)
            } else if let stringValue = descriptor.stringValue {
                url = URL(fileURLWithPath: stringValue)
            } else {
                url = nil
            }
            guard let fileURL = url else { continue }

            if store.hasVisibleWindow, store.openWindowAction != nil {
                store.openFromFinder(fileURL)
            } else {
                store.enqueue(fileURL)
            }
        }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if !store.hasVisibleWindow {
                // No window to show the file in; reopening the app creates one, and that
                // window picks up the queued files.
                NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.bundlePath))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = DocumentStore.shared
        let failed = store.flushForTermination()
        guard !failed.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Some changes could not be saved"
        alert.informativeText = "Could not write: " + failed.map(\.title).joined(separator: ", ")
            + ". Quit anyway and lose those changes?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            return .terminateNow
        }
        store.isTerminating = false
        return .terminateCancel
    }
}

// MARK: - File menu

struct FileCommands: Commands {
    @FocusedValue(\.document) var document
    @FocusedValue(\.richEditorController) var controller
    @FocusedValue(\.windowUIState) var uiState
    @Environment(\.openWindow) private var openWindow

    private var store: DocumentStore { .shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                let document = store.newDocument()
                openWindow(value: document.id)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open…") {
                store.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                ForEach(store.recents) { entry in
                    Button(entry.name) { store.openRecent(entry) }
                        .help(entry.url.path)
                }
                if !store.recents.isEmpty {
                    Divider()
                    Button("Clear Menu") { store.clearRecents() }
                }
            }

            Button("Quick Open…") {
                uiState?.showQuickOpen = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(uiState == nil)

            Button("New Sheet in Library") {
                if let url = LibraryModel.shared.newSheet(), let document = store.openDocument(at: url) {
                    store.show(document)
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(LibraryModel.shared.folderURL == nil)

            Divider()

            Button("Split at Cursor") {
                guard let document, let parts = controller?.splitAtCursor?() else { return }
                document.text = parts.0
                document.textDidChange()
                let second = store.newDocument(text: parts.1)
                openWindow(value: second.id)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(document == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Save") {
                if let document { store.save(document) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(document == nil)

            Button("Save As…") {
                if let document { store.saveAs(document) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(document == nil)

            Button("Save a Version") {
                document?.saveVersion()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(document?.isUntitled ?? true)

            Divider()

            Button("Export Preview…") {
                uiState?.showExportPreview = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(document == nil)

            Menu("Export") {
                Button("HTML…") { if let document { Exporter.exportHTML(document) } }
                Button("PDF…") { if let document { Exporter.exportPDF(document, window: NSApp.keyWindow) } }
                Button("Word (.docx)…") { if let document { Exporter.exportWord(document) } }
                Button("Rich Text (.rtf)…") { if let document { Exporter.exportRTF(document) } }
                Divider()
                Button("Copy as HTML") { if let document { Exporter.copyHTML(document) } }
            }
            .disabled(document == nil)

            Menu("Revert To") {
                if let document, !document.isUntitled {
                    Button("Last Opened") { document.revertToOpened() }
                        .disabled(document.text == document.openedText)
                    if !document.versions.isEmpty {
                        Divider()
                        ForEach(document.versions) { version in
                            Button(version.label) { document.revert(to: version) }
                        }
                    }
                }
            }
            .disabled(document?.isUntitled ?? true)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                if let document { Exporter.print(document, window: NSApp.keyWindow) }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(document == nil)
        }
    }
}

/// Format menu for the rendered editor. Items are disabled while the raw editor is showing.
struct FormatCommands: Commands {
    @FocusedValue(\.richEditorController) var controller

    private var isActive: Bool { controller?.isActive ?? false }

    var body: some Commands {
        CommandMenu("Format") {
            Group {
            Button("Bold") { controller?.toggleBold() }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { controller?.toggleItalic() }
                .keyboardShortcut("i", modifiers: .command)
            Button("Strikethrough") { controller?.toggleStrikethrough() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Inline Code") { controller?.toggleInlineCode() }
                .keyboardShortcut("e", modifiers: .command)
            Button("Highlight") { controller?.toggleHighlight() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Link…") { controller?.requestLink() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Footnote") { controller?.insertFootnote() }
                .keyboardShortcut("f", modifiers: [.command, .shift, .option])

            Divider()

            Button("Paragraph") { controller?.setHeading(nil) }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { controller?.setHeading(level) }
                    .keyboardShortcut(KeyEquivalent(Character(String(level))), modifiers: .command)
            }

            Divider()

            Button("Bulleted List") { controller?.toggleBulletList() }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { controller?.toggleOrderedList() }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Task List") { controller?.toggleTaskList() }
                .keyboardShortcut("9", modifiers: [.command, .shift])
            Button("Blockquote") { controller?.toggleBlockquote() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Code Block") { controller?.toggleCodeBlock() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Comment") { controller?.toggleComment() }
                .keyboardShortcut("/", modifiers: [.command, .shift])

            Divider()

            Button("Horizontal Rule") { controller?.insertHorizontalRule() }
            Button("Table…") { controller?.requestTable() }
            Button("Image…") { controller?.requestImage() }

            Divider()

            Button("Increase Indent") { controller?.increaseIndent() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Decrease Indent") { controller?.decreaseIndent() }
                .keyboardShortcut("[", modifiers: .command)

            Divider()

            Button("Fold or Unfold Section") { controller?.toggleFold() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Unfold All Sections") { controller?.unfoldAll() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            }
            .disabled(!isActive)
        }
    }
}

// MARK: - Edit menu additions (find bar, spelling & grammar)

struct EditCommands: Commands {
    /// Sends a standard AppKit text action to the first responder.
    private static func send(_ selector: Selector, tag: Int? = nil) {
        let item = NSMenuItem()
        if let tag { item.tag = tag }
        NSApp.sendAction(selector, to: nil, from: item)
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { Self.send(#selector(NSTextView.performFindPanelAction(_:)), tag: 1) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find and Replace…") { Self.send(#selector(NSTextView.performFindPanelAction(_:)), tag: 12) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { Self.send(#selector(NSTextView.performFindPanelAction(_:)), tag: 2) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { Self.send(#selector(NSTextView.performFindPanelAction(_:)), tag: 3) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Hide Find Bar") { Self.send(#selector(NSTextView.performFindPanelAction(_:)), tag: 13) }
            }
            Menu("Spelling and Grammar") {
                Button("Show Spelling and Grammar") { Self.send(#selector(NSText.showGuessPanel(_:))) }
                    .keyboardShortcut(":", modifiers: .command)
                Button("Check Document Now") { Self.send(#selector(NSText.checkSpelling(_:))) }
                    .keyboardShortcut(";", modifiers: .command)
                Divider()
                Button("Check Spelling While Typing") { Self.send(#selector(NSTextView.toggleContinuousSpellChecking(_:))) }
                Button("Check Grammar With Spelling") { Self.send(#selector(NSTextView.toggleGrammarChecking(_:))) }
                Button("Correct Spelling Automatically") { Self.send(#selector(NSTextView.toggleAutomaticSpellingCorrection(_:))) }
            }
        }
    }
}

// MARK: - View menu (writing environment)

struct ViewCommands: Commands {
    @FocusedValue(\.windowUIState) var uiState

    private var settings: ViewSettings { .shared }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Toggle("Typewriter Scrolling", isOn: Binding(
                get: { settings.typewriterScrolling },
                set: { settings.typewriterScrolling = $0 }))
                .keyboardShortcut("t", modifiers: [.command, .option])

            Picker("Focus Mode", selection: Binding(
                get: { settings.focusMode },
                set: { settings.focusMode = $0 })) {
                Text("Off").tag(FocusMode.off)
                Text("Paragraph").tag(FocusMode.paragraph)
                Text("Sentence").tag(FocusMode.sentence)
            }

            Button(uiState?.isComposing == true ? "Exit Composition Mode" : "Enter Composition Mode") {
                uiState?.toggleComposition()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(uiState == nil)

            Divider()

            Toggle("Show Library", isOn: Binding(
                get: { settings.showLibrary },
                set: { settings.showLibrary = $0 }))
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Show Dashboard", isOn: Binding(
                get: { settings.showDashboard },
                set: { settings.showDashboard = $0 }))
                .keyboardShortcut("d", modifiers: [.command, .option])

            Divider()
        }
    }
}
