//
//  ContentView.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Which face of the single editor pane is showing.
enum EditorMode: String, CaseIterable, Identifiable {
    case rendered
    case raw

    var id: String { rawValue }
}

/// Hosts one document per window (tab). Resolves which document the window shows and
/// registers the window with the store.
struct DocumentWindowView: View {
    @Binding var documentID: UUID?
    @Environment(\.openWindow) private var openWindow
    @State private var document: Document? = nil
    @State private var window: NSWindow? = nil

    var body: some View {
        Group {
            if let document {
                ContentView(document: document)
            } else {
                Color.clear
            }
        }
        .background(WindowAccessor { window = $0 })
        .onAppear(perform: resolve)
        .onChange(of: window) { _, _ in register() }
        .onChange(of: document?.id) { _, _ in register() }
    }

    private func resolve() {
        let store = DocumentStore.shared
        store.openWindowAction = { [openWindow] id in openWindow(value: id) }
        if let id = documentID, let existing = store.document(id: id) {
            document = existing
            register()
            return
        }
        let documents = store.initialDocuments()
        document = documents[0]
        documentID = documents[0].id
        register()
        if documents.count > 1 {
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                for other in documents.dropFirst() {
                    openWindow(value: other.id)
                }
            }
        }
    }

    private func register() {
        guard let window, let document else { return }
        DocumentStore.shared.register(window: window, for: document)
    }
}

/// Per-window UI state that menu commands need to reach.
@MainActor
@Observable
final class WindowUIState {
    var isComposing = false
    var showQuickOpen = false
    var showExportPreview = false
    weak var window: NSWindow? = nil

    /// Composition mode: full screen, bars hidden, just the text.
    func toggleComposition() {
        isComposing.toggle()
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if isComposing != isFullScreen {
            window.toggleFullScreen(nil)
        }
    }
}

struct ContentView: View {
    @Bindable var document: Document
    @State private var showCheatSheet = false
    @State private var controller = RichEditorController()
    @State private var uiState = WindowUIState()
    @AppStorage("editorMode") private var editorMode: EditorMode = .rendered
    private var theme = ThemeSettings.shared
    private var viewSettings = ViewSettings.shared

    init(document: Document) {
        self.document = document
    }

    private var editorStyle: EditorStyle { EditorStyle(theme: theme) }

    private var editorOptions: EditorOptions {
        var options = EditorOptions()
        options.typewriter = viewSettings.typewriterScrolling
        options.focus = viewSettings.focusMode
        options.maxWidth = CGFloat(theme.editorMaxWidth)
        options.composition = uiState.isComposing
        if uiState.isComposing && options.maxWidth == 0 { options.maxWidth = 720 }
        return options
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if editorMode == .rendered {
                if !uiState.isComposing {
                    FormattingToolbar(controller: controller, documentURL: document.fileURL)
                    Divider()
                }
                RichMarkdownEditorView(
                    text: $document.text,
                    style: editorStyle,
                    options: editorOptions,
                    baseURL: document.fileURL,
                    controller: controller
                )
            } else {
                MarkdownEditorView(text: $document.text, style: editorStyle, options: editorOptions, controller: controller)
            }

            if !uiState.isComposing {
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 460)
        .layoutPriority(1)
    }

    var body: some View {
        HStack(spacing: 0) {
            if viewSettings.showLibrary && !uiState.isComposing {
                LibraryView(currentFileURL: document.fileURL)
                    .frame(width: 250)
                Divider()
            }
            editorColumn
            if viewSettings.showDashboard && !uiState.isComposing {
                Divider()
                DashboardView(text: $document.text, goalKey: document.goalKey, fileURL: document.fileURL,
                              onJumpToHeading: { controller.jumpToHeading?($0) },
                              backlinks: currentBacklinks,
                              onOpenBacklink: { url in
                                  let store = DocumentStore.shared
                                  if let linked = store.openDocument(at: url) { store.show(linked) }
                              },
                              onOpenWikiLink: { target in WikiLinkResolver.open(target, near: document.fileURL) },
                              onSelectTag: { tag in
                                  LibraryModel.shared.selectedKeyword = tag
                                  LibraryModel.shared.searchText = ""
                                  viewSettings.showLibrary = true
                              },
                              onJumpToTag: { tag in controller.jump(toText: "#" + tag) })
                    .frame(width: 270)
            }
        }
        .sheet(isPresented: $uiState.showQuickOpen) { QuickOpenView() }
        .sheet(isPresented: $uiState.showExportPreview) { ExportPreviewView(document: document) }
        .background(WindowAccessor { uiState.window = $0 })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === uiState.window, uiState.isComposing {
                uiState.isComposing = false
            }
        }
        .toolbar(uiState.isComposing ? .hidden : .visible, for: .windowToolbar)
        .frame(minWidth: 460 + (viewSettings.showLibrary && !uiState.isComposing ? 251 : 0)
                         + (viewSettings.showDashboard && !uiState.isComposing ? 271 : 0),
               minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewSettings.showLibrary.toggle()
                } label: {
                    Label("Library", systemImage: "sidebar.left")
                }
                .help(viewSettings.showLibrary ? "Hide Library (⌘⌥L)" : "Show Library (⌘⌥L)")
            }

            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $editorMode) {
                    Label("Rendered", systemImage: "doc.richtext").tag(EditorMode.rendered)
                    Label("Raw", systemImage: "chevron.left.forwardslash.chevron.right").tag(EditorMode.raw)
                }
                .pickerStyle(.segmented)
                .help("Switch between the rendered editor and raw Markdown")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showCheatSheet.toggle()
                } label: {
                    Label("Cheat Sheet", systemImage: "list.bullet.rectangle")
                }
                .help("Markdown Cheat Sheet")

                Button {
                    viewSettings.showDashboard.toggle()
                } label: {
                    Label("Dashboard", systemImage: "sidebar.right")
                }
                .help(viewSettings.showDashboard ? "Hide Dashboard (⌘⌥D)" : "Show Dashboard (⌘⌥D)")
            }
        }
        .sheet(isPresented: $showCheatSheet) {
            MarkdownCheatSheet()
        }
        .onChange(of: document.text) { _, _ in
            document.textDidChange()
        }
        .onChange(of: document.fileURL, initial: true) { _, url in
            controller.documentURL = url
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            document.autosaveNow()
        }
        .navigationTitle(document.windowTitle)
        .focusedSceneValue(\.richEditorController, controller)
        .focusedSceneValue(\.document, document)
        .focusedSceneValue(\.windowUIState, uiState)
    }

    // MARK: - Backlinks

    /// Sheets linking here: from the library index plus the live text of open tabs
    /// (which may not be saved or indexed yet).
    private var currentBacklinks: [BacklinkEntry] {
        guard let url = document.fileURL else { return [] }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        var seen: Set<String> = []
        var entries: [BacklinkEntry] = []
        for other in DocumentStore.shared.documents where other !== document {
            guard let otherURL = other.fileURL else { continue }
            let targets = TextStatistics.wikiLinks(markdown: other.text).map { $0.lowercased() }
            guard targets.contains(name), seen.insert(otherURL.standardizedFileURL.path).inserted else { continue }
            entries.append(BacklinkEntry(url: otherURL, name: otherURL.deletingPathExtension().lastPathComponent))
        }
        for node in LibraryModel.shared.backlinks(to: url) where seen.insert(node.url.standardizedFileURL.path).inserted {
            // Skip open documents whose live text no longer links here.
            if DocumentStore.shared.document(for: node.url) != nil { continue }
            entries.append(BacklinkEntry(url: node.url, name: node.name))
        }
        return entries
    }

    // MARK: - Status bar

    private var statusBar: some View {
        let stats = TextStatistics.compute(markdown: document.text)
        let goal = GoalStore.shared.goal(for: document.goalKey)
        return HStack {
            Image(systemName: editorMode == .rendered ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.secondary)
            Text(editorMode == .rendered ? "Rendered" : "Raw Markdown")
                .foregroundStyle(.secondary)
            if ViewSettings.shared.focusMode != .off {
                Text("· Focus: \(ViewSettings.shared.focusMode.label)").foregroundStyle(.tertiary)
            }
            if ViewSettings.shared.typewriterScrolling {
                Text("· Typewriter").foregroundStyle(.tertiary)
            }
            Spacer()
            if let goal {
                let current = goal.current(from: stats)
                ProgressView(value: goal.fraction(current: current))
                    .frame(width: 60)
                    .tint(goal.isMet(current: current) ? .green : .accentColor)
                Text("\(current.formatted()) / \(goal.target.formatted()) \(goal.kind.label.lowercased())")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
            }
            Text("\(stats.words.formatted()) words")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text("\(stats.characters.formatted()) chars")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text(stats.readingMinutes == 0 ? "" : "\(stats.readingMinutes) min read")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Sample markdown for first launch

    static let sampleMarkdown = """
# Welcome to Marky Mark

A Markdown editor with a **rendered** view you can *edit directly* and a ***raw*** view for hand-written markup.

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

- [x] Build the raw Markdown editor
- [x] Build the rendered editor
- [x] Add a formatting toolbar
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

Type here and use the toolbar to format your text, or switch to **Raw** in the window toolbar to write the Markdown yourself. The **Cheat Sheet** button shows every supported syntax.

Happy writing!
"""

}

// MARK: - Focused value for menu commands

struct DocumentFocusKey: FocusedValueKey {
    typealias Value = Document
}

struct WindowUIStateKey: FocusedValueKey {
    typealias Value = WindowUIState
}

extension FocusedValues {
    var document: Document? {
        get { self[DocumentFocusKey.self] }
        set { self[DocumentFocusKey.self] = newValue }
    }

    var windowUIState: WindowUIState? {
        get { self[WindowUIStateKey.self] }
        set { self[WindowUIStateKey.self] = newValue }
    }
}
