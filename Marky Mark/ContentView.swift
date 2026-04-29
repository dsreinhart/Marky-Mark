//
//  ContentView.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var markdownText: String = ""
    @State private var lastSavedText: String = ""
    @State private var scrollFraction: CGFloat = 0
    @State private var parsedBlocks: [MarkdownBlock] = []
    @State private var showCheatSheet = false
    @State private var showEditor = true
    @State private var showPreview = true
    @State private var currentFileURL: URL? = nil
    @State private var hasUnsavedChanges = false
    @State private var fileBookmarkData: Data? = nil
    private static let bookmarkKey = "lastOpenedFileBookmark"

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "pencil.and.outline")
                    .foregroundStyle(.secondary)
                Text("Markdown")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(markdownText.count) chars")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            MarkdownEditorView(text: $markdownText, scrollFraction: $scrollFraction)
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text("Preview")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(parsedBlocks.count) blocks")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            MarkdownPreviewView(blocks: parsedBlocks, scrollFraction: $scrollFraction)
        }
    }

    var body: some View {
        Group {
            if showEditor && showPreview {
                HSplitView {
                    editorPane.frame(minWidth: 300)
                    previewPane.frame(minWidth: 300)
                }
            } else if showEditor {
                editorPane
            } else {
                previewPane
            }
        }
        .frame(minWidth: showEditor && showPreview ? 700 : 350, minHeight: 400)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if showEditor && !showPreview {
                        showPreview = true
                    } else {
                        showEditor.toggle()
                    }
                } label: {
                    Label("Editor", systemImage: showEditor ? "pencil.and.outline" : "pencil.slash")
                }
                .help(showEditor ? "Hide Editor" : "Show Editor")

                Button {
                    if !showEditor && showPreview {
                        showEditor = true
                    } else {
                        showPreview.toggle()
                    }
                } label: {
                    Label("Preview", systemImage: showPreview ? "eye" : "eye.slash")
                }
                .help(showPreview ? "Hide Preview" : "Show Preview")

                Button {
                    showCheatSheet.toggle()
                } label: {
                    Label("Cheat Sheet", systemImage: "list.bullet.rectangle")
                }
                .help("Markdown Cheat Sheet")
            }
        }
        .sheet(isPresented: $showCheatSheet) {
            MarkdownCheatSheet()
        }
        .onChange(of: markdownText) { _, newValue in
            parsedBlocks = MarkdownParser.parse(newValue)
            markUnsavedChanges(newValue != lastSavedText)
        }
        .onAppear {
            // Check if the app was launched via "Open With..." before restoring the last file.
            if let pending = DocumentState.shared.pendingFileURL {
                DocumentState.shared.pendingFileURL = nil
                loadFileDirectly(from: pending)
            } else {
                restoreLastFile()
            }

            parsedBlocks = MarkdownParser.parse(markdownText)
            markUnsavedChanges(false)
            DocumentState.shared.saveAction = { [self] in saveDocument() }
            DocumentState.shared.openFileAction = { [self] url in openFileFromFinder(url) }
        }
        .onDisappear {
            DocumentState.shared.openFileAction = nil
            DocumentState.shared.saveAction = nil
        }
        .navigationTitle(windowTitle)
        .focusedValue(\.documentActions, DocumentActions(
            newDocument: newDocument,
            openDocument: openDocument,
            saveDocument: saveDocument,
            saveDocumentAs: saveDocumentAs
        ))
    }

    private func markUnsavedChanges(_ value: Bool) {
        hasUnsavedChanges = value
        DocumentState.shared.hasUnsavedChanges = value
    }

    // MARK: - Window title

    private var windowTitle: String {
        let name = currentFileURL?.lastPathComponent ?? "Untitled"
        return hasUnsavedChanges ? "\(name) — Edited" : name
    }

    // MARK: - File operations

    private func newDocument() {
        guard confirmDiscardChanges() else { return }
        markdownText = ""
        lastSavedText = ""
        currentFileURL = nil
        fileBookmarkData = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        markUnsavedChanges(false)
    }

    private func restoreLastFile() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            markdownText = Self.sampleMarkdown
            lastSavedText = Self.sampleMarkdown
            return
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // Treat trashed or missing files as deleted.
            if url.path.contains("/.Trash/") || !FileManager.default.fileExists(atPath: url.path) {
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
                markdownText = Self.sampleMarkdown
                lastSavedText = Self.sampleMarkdown
                return
            }

            guard url.startAccessingSecurityScopedResource() else {
                markdownText = Self.sampleMarkdown
                lastSavedText = Self.sampleMarkdown
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            if isStale { saveBookmark(for: url) }

            let content = try String(contentsOf: url, encoding: .utf8)
            markdownText = content
            lastSavedText = content
            currentFileURL = url
            fileBookmarkData = bookmarkData
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            markdownText = Self.sampleMarkdown
            lastSavedText = Self.sampleMarkdown
        }
    }

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            fileBookmarkData = data
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            print("Could not save bookmark: \(error.localizedDescription)")
        }
    }

    /// Loads a file without prompting for unsaved changes — used at launch via "Open With...".
    private func loadFileDirectly(from url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            markdownText = content
            lastSavedText = content
            currentFileURL = url
            saveBookmark(for: url)
            markUnsavedChanges(false)
        } catch {
            // Fall back to restoring the last file if the "Open With" file can't be read
            restoreLastFile()
        }
    }

    private func openFileFromFinder(_ url: URL) {
        guard confirmDiscardChanges() else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            markdownText = content
            lastSavedText = content
            currentFileURL = url
            saveBookmark(for: url)
            markUnsavedChanges(false)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open file"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func openDocument() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Markdown file to open"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                markdownText = content
                lastSavedText = content
                currentFileURL = url
                saveBookmark(for: url)
                markUnsavedChanges(false)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not open file"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func saveDocument() {
        if currentFileURL != nil {
            guard let bookmarkData = fileBookmarkData else {
                saveDocumentAs()
                return
            }
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard url.startAccessingSecurityScopedResource() else {
                    saveDocumentAs()
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                if isStale { saveBookmark(for: url) }
                writeFile(to: url)
            } catch {
                saveDocumentAs()
            }
        } else {
            saveDocumentAs()
        }
    }

    private func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.md"
        panel.message = "Save your Markdown file"

        if panel.runModal() == .OK, let url = panel.url {
            writeFile(to: url)
        }
    }

    private func writeFile(to url: URL) {
        do {
            try markdownText.write(to: url, atomically: true, encoding: .utf8)
            lastSavedText = markdownText
            currentFileURL = url
            saveBookmark(for: url)
            markUnsavedChanges(false)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save file"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Shows a Save/Don't Save/Cancel alert if there are unsaved changes.
    /// Returns `true` if the caller should proceed, `false` to cancel.
    private func confirmDiscardChanges() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "Do you want to save changes?"
        let name = currentFileURL?.lastPathComponent ?? "Untitled"
        alert.informativeText = "Your changes to \"\(name)\" will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveDocument()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: - Sample markdown for first launch

    private static let sampleMarkdown = """
# Welcome to Marky Mark

A **live** Markdown editor with *real-time* preview and ***full syntax*** support.

## Text Formatting

You can make text **bold**, *italic*, or ***both at once***. You can also ~~strike through~~ text that's no longer relevant. Inline `code` looks great too.

## Links & Images

Visit [Apple Developer](https://developer.apple.com) for the latest docs.

Here's an image reference: ![Swift Logo](https://swift.org/logo.png)

## Blockquotes

> "All you need is love... and a good Markdown editor."
> — The Beatles, probably

## Lists

Unordered list:
- **John** — the dreamer
- **Paul** — the melodist
- **George** — the quiet one
- **Ringo** — the heartbeat

Ordered list:
1. Write some Markdown
2. Watch the preview update
3. Profit

Nested list:
- Fruits
  - Apples
  - Oranges
- Vegetables
  - Carrots
  - Peas

## Task Lists

- [x] Build the editor pane
- [x] Build the preview pane
- [x] Add scroll synchronization
- [x] Support full Markdown syntax
- [ ] Take over the world

## Tables

| Feature | Status | Notes |
|---------|--------|-------|
| Headings | Done | H1-H6 |
| Bold/Italic | Done | And combined |
| Code blocks | Done | With language hints |
| Blockquotes | Done | Multi-line support |
| Tables | Done | You're looking at one |
| Task lists | Done | Checkboxes! |

## Code Example

```swift
struct HelloWorld: View {
    var body: some View {
        Text("Hello, Marky Mark!")
            .font(.largeTitle)
            .bold()
    }
}
```

---

### Try It Yourself

Edit this text to see the preview update in real time. Click the **?** button or use the toolbar to open the **Markdown Cheat Sheet** for a full syntax reference.

Happy writing!
"""
}

// MARK: - Shared document state for app delegate access

@Observable
final class DocumentState {
    static let shared = DocumentState()
    var hasUnsavedChanges = false
    var saveAction: (() -> Void)? = nil
    var openFileAction: ((URL) -> Void)? = nil
    var pendingFileURL: URL? = nil
    private init() {}
}

// MARK: - Focused value for menu commands

struct DocumentActions {
    var newDocument: () -> Void
    var openDocument: () -> Void
    var saveDocument: () -> Void
    var saveDocumentAs: () -> Void
}

struct DocumentActionsKey: FocusedValueKey {
    typealias Value = DocumentActions
}

extension FocusedValues {
    var documentActions: DocumentActions? {
        get { self[DocumentActionsKey.self] }
        set { self[DocumentActionsKey.self] = newValue }
    }
}

#Preview {
    ContentView()
}
