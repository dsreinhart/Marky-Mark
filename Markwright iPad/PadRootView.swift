//
//  PadRootView.swift
//  Markwright iPad
//
//  One window: the library sidebar and the sheet it shows. The window remembers its sheet
//  (the scene's value), so a relaunch brings each window back to where it was. At a compact
//  width (iPhone) the two collapse into one stack: the library first, a sheet pushed over it.
//

import SwiftUI

struct PadRootView: View {
    @Binding var fileURL: URL?
    @State private var document: Document? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var columns: NavigationSplitViewVisibility = .automatic
    @State private var columnsBeforeComposition: NavigationSplitViewVisibility = .automatic
    /// What a compact width shows: the library, or the sheet (with a back button to the library).
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showQuickOpen = false
    @State private var isComposing = false
    @State private var newSheetFailed = false
    @Environment(\.openWindow) private var openWindow
    private var library = LibraryModel.shared

    init(fileURL: Binding<URL?>) {
        _fileURL = fileURL
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            PadLibraryView(currentURL: document?.fileURL,
                           onOpen: { url, search in open(url, jumpingTo: search) },
                           onOpenInNewWindow: { openWindow(value: $0) },
                           onQuickOpen: { showQuickOpen = true })
                .modifier(PhoneSidebarToggle(showsHide: sizeClass != .compact, hide: { columns = .detailOnly }))
        } detail: {
            if let document {
                PadDocumentView(document: document, isComposing: $isComposing,
                                onOpenFile: { open($0, jumpingTo: nil) },
                                onQuickOpen: { showQuickOpen = true },
                                showsLibraryButton: sizeClass != .compact && (columns == .detailOnly || !PadPlatform.isPad),
                                onToggleLibrary: { toggleLibrary() })
                    .id(document.id)
            } else {
                NavigationStack { welcome }
            }
        }
        .onAppear {
            // Nothing to show yet: start with the library open.
            if fileURL == nil { columns = .all } else { compactColumn = .detail }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .task(id: fileURL) { await load() }
        .onOpenURL { url in
            PadDocuments.shared.noteOpenedFromOutside(url)
            open(url, jumpingTo: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .padFileMoved)) { note in
            guard let old = note.userInfo?["old"] as? URL, let new = note.userInfo?["new"] as? URL,
                  let current = fileURL else { return }
            let oldPath = Document.stablePath(old), path = Document.stablePath(current)
            if path == oldPath {
                fileURL = new
            } else if path.hasPrefix(oldPath + "/") {
                fileURL = new.appending(path: String(path.dropFirst(oldPath.count + 1)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .padFileDeleted)) { note in
            guard let gone = note.userInfo?["url"] as? URL, let current = fileURL else { return }
            let gonePath = Document.stablePath(gone), path = Document.stablePath(current)
            if path == gonePath || path.hasPrefix(gonePath + "/") {
                document = nil
                fileURL = nil
                compactColumn = .sidebar
            }
        }
        .onChange(of: isComposing) { _, composing in
            if composing {
                columnsBeforeComposition = columns
                columns = .detailOnly
            } else {
                columns = columnsBeforeComposition
            }
        }
        .sheet(isPresented: $showQuickOpen) {
            PadQuickOpenView { url in open(url, jumpingTo: nil) }
        }
        .alert("Couldn't Open", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .focusedSceneValue(\.padWindow, PadWindowActions(
            newSheet: { newSheet() },
            quickOpen: { showQuickOpen = true },
            toggleLibrary: { toggleLibrary() }
        ))
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label(isLoading ? "Opening\u{2026}" : "No Sheet Open", systemImage: "doc.text")
        } description: {
            if !isLoading {
                Text(library.folderURL == nil
                     ? "Choose a library folder in the sidebar, or open a document from Files."
                     : "Pick a sheet in the library, or start a new one.")
            }
        } actions: {
            if !isLoading {
                Button("New Sheet") { newSheet() }
                    .buttonStyle(.borderedProminent)
                Button("Quick Open\u{2026}") { showQuickOpen = true }
            }
        }
        .alert("Couldn't Create a Sheet", isPresented: $newSheetFailed) {
            Button("OK") {}
        }
    }

    // MARK: - Actions

    private func open(_ url: URL, jumpingTo search: String?) {
        compactColumn = .detail
        if let document, let current = document.fileURL, Document.stablePath(current) == Document.stablePath(url) {
            if let search { document.pendingJump = .init(text: search) }
            return
        }
        document?.autosaveNow()
        if let search, let existing = PadDocuments.shared.document(at: url) {
            existing.pendingJump = .init(text: search)
        } else if let search {
            pendingSearch = search
        }
        fileURL = url
        // In a narrow window the sidebar covers the sheet; get it out of the way.
        if windowWidth < 1000 && columns != .detailOnly { columns = .detailOnly }
    }

    @State private var windowWidth: CGFloat = 1200

    /// A search jump asked for before the sheet was read.
    @State private var pendingSearch: String? = nil

    private func load() async {
        guard let url = fileURL else {
            document = nil
            return
        }
        if let document, let current = document.fileURL, Document.stablePath(current) == Document.stablePath(url) { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let opened = try await PadDocuments.shared.document(for: url)
            if let search = pendingSearch {
                opened.pendingJump = .init(text: search)
                pendingSearch = nil
            }
            document = opened
        } catch {
            errorMessage = error.localizedDescription
            document = nil
            fileURL = nil
            compactColumn = .sidebar
        }
    }

    private func newSheet() {
        guard let url = PadDocuments.shared.newDocumentURL() else {
            newSheetFailed = true
            return
        }
        open(url, jumpingTo: nil)
    }

    private func toggleLibrary() {
        if PadPlatform.isPad {
            columns = columns == .detailOnly ? .all : .detailOnly
        } else {
            // A phone starts "automatic", which may already be hiding it: one tap shows it.
            columns = columns == .all ? .detailOnly : .all
        }
    }
}

/// Window commands the menu bar and keyboard shortcuts reach (see PadCommands).
struct PadWindowActions {
    let newSheet: () -> Void
    let quickOpen: () -> Void
    let toggleLibrary: () -> Void
}

extension FocusedValues {
    @Entry var padWindow: PadWindowActions? = nil
    @Entry var padDocument: PadDocumentActions? = nil
}

/// On iPhone the split view's own sidebar button appears only after a rotation from portrait,
/// beside the sheet's Library button, so it is removed there. In its place, while the library
/// floats over the sheet (a wide iPhone), the library has its own button to put it away; the sheet's
/// Library button brings it back. The iPad keeps the system's button.
private struct PhoneSidebarToggle: ViewModifier {
    /// The window is wide (the library floats over the sheet). Not the sidebar's own size class,
    /// which is always compact.
    let showsHide: Bool
    let hide: () -> Void

    func body(content: Content) -> some View {
        if PadPlatform.isPad {
            content
        } else {
            content
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if showsHide {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: hide) {
                                Label("Hide Library", systemImage: "sidebar.left")
                            }
                        }
                    }
                }
        }
    }
}
