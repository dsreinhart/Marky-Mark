//
//  PadLibraryView.swift
//  Markwright iPad
//
//  The sidebar: the library folder's sheets and groups, with search and tags, plus documents
//  opened from elsewhere. Tapping a sheet shows it in this window.
//

import SwiftUI
import UniformTypeIdentifiers

struct PadLibraryView: View {
    let currentURL: URL?
    /// Shows a file in this window; the string is a search term to jump to.
    let onOpen: (URL, String?) -> Void
    let onOpenInNewWindow: (URL) -> Void
    let onQuickOpen: () -> Void

    @State private var showFolderPicker = false
    @State private var showDocumentPicker = false
    @State private var renameTarget: LibraryNode? = nil
    @State private var renameText = ""
    @State private var deleteTarget: LibraryNode? = nil
    @State private var newGroupFolder: URL? = nil
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var errorMessage: String? = nil
    @AppStorage("library.tagsExpanded") private var tagsExpanded = true
    private var library = LibraryModel.shared
    private var documents = PadDocuments.shared

    init(currentURL: URL?, onOpen: @escaping (URL, String?) -> Void,
         onOpenInNewWindow: @escaping (URL) -> Void, onQuickOpen: @escaping () -> Void) {
        self.currentURL = currentURL
        self.onOpen = onOpen
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onQuickOpen = onQuickOpen
    }

    private var query: String { library.searchText.trimmingCharacters(in: .whitespaces) }

    /// Documents opened from outside the library.
    private var outsideRecents: [URL] {
        documents.recents.filter { !library.contains($0) }
    }

    var body: some View {
        List {
            if library.folderURL == nil {
                chooseFolderSection
            } else if library.isFiltering {
                searchResults
            } else if let root = library.root {
                Section {
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        row(node)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(root.name)
                        if library.isScanning { ProgressView().controlSize(.mini) }
                    }
                }
                if !library.tagTree.isEmpty { tagSection }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if !outsideRecents.isEmpty && !library.isFiltering {
                Section("Opened from Files") {
                    ForEach(outsideRecents, id: \.self) { url in
                        recentRow(url)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .searchable(text: Binding(get: { library.searchText }, set: { library.searchText = $0 }),
                    placement: .sidebar, prompt: "Search sheets and text")
        .toolbar { toolbarContent }
        .refreshable { library.refresh() }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(startingAt: library.folderURL) { folder in
                showFolderPicker = false
                guard let folder else { return }
                if PadFolderAccess.grant(folder) == .refused {
                    errorMessage = "iPadOS didn't give Markwright access to \u{201C}\(folder.lastPathComponent)\u{201D}. Try again."
                    return
                }
                library.setFolder(folder)
            }
        }
        .fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: [.markdownDocument, .plainText]) { result in
            switch result {
            case .success(let url):
                documents.noteOpenedFromOutside(url)
                onOpen(url, nil)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { renameNow() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                if !library.newGroup(in: newGroupFolder, named: newGroupName) {
                    errorMessage = "Couldn't create the group \u{201C}\(newGroupName)\u{201D}."
                }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteNow() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("It moves to Recently Deleted in the Files app where iPadOS allows it; otherwise it's removed for good.")
        }
        .alert("Couldn't Do That", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var chooseFolderSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("No library folder", systemImage: "books.vertical").font(.headline)
                Text("Choose a folder, for example the one in iCloud Drive that your Mac uses, and its Markdown files become sheets and its subfolders groups.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Choose Folder\u{2026}") { showFolderPicker = true }
                    .buttonStyle(.borderedProminent)
                Button("Open a Document\u{2026}") { showDocumentPicker = true }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let files = library.filteredFiles
        Section {
            ForEach(files) { node in
                row(node, jumpingTo: query.isEmpty ? nil : query)
            }
        } header: {
            Text(filterSummary(count: files.count))
                .textCase(nil)
        }
        if library.selectedKeyword != nil {
            Section {
                Button("Show All Sheets", systemImage: "xmark.circle") { library.selectedKeyword = nil }
            }
        }
    }

    private var tagSection: some View {
        Section(isExpanded: $tagsExpanded) {
            PadTagRows(nodes: library.tagTree, depth: 0, selected: library.selectedKeyword) { path in
                library.selectedKeyword = library.selectedKeyword == path ? nil : path
            }
        } header: {
            Text("Tags")
        }
    }

    /// "2 sheets tagged #test/alpha", "1 sheet matching “plan”", or both.
    private func filterSummary(count: Int) -> String {
        var text = count == 1 ? "1 sheet" : "\(count) sheets"
        if let keyword = library.selectedKeyword { text += " tagged #\(keyword)" }
        if !query.isEmpty { text += (library.selectedKeyword == nil ? " matching \u{201C}" : " and matching \u{201C}") + query + "\u{201D}" }
        return text
    }

    private func isCurrent(_ url: URL) -> Bool {
        guard let currentURL else { return false }
        return Document.stablePath(url) == Document.stablePath(currentURL)
    }

    @ViewBuilder
    private func row(_ node: LibraryNode, jumpingTo search: String? = nil) -> some View {
        if node.isFolder {
            Label {
                HStack {
                    Text(node.name).lineLimit(1)
                    Spacer()
                    Text("\(node.allFiles.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            } icon: {
                Image(systemName: "folder").foregroundStyle(Color.accentColor)
            }
            .contextMenu { folderMenu(node) }
        } else {
            Button {
                onOpen(node.url, search)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).lineLimit(1).foregroundStyle(Color.primary)
                        if let snippet = matchSnippet(node) {
                            Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text("\(node.wordCount.formatted()) words" + (node.keywords.isEmpty ? "" : " \u{00B7} " + node.keywords.joined(separator: ", ")))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .listRowBackground(isCurrent(node.url) ? Color.accentColor.opacity(0.18) : nil)
            .contextMenu { fileMenu(node) }
        }
    }

    private func recentRow(_ url: URL) -> some View {
        Button {
            onOpen(url, nil)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1).foregroundStyle(Color.primary)
                    Text(url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            } icon: {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
        }
        .listRowBackground(isCurrent(url) ? Color.accentColor.opacity(0.18) : nil)
        .contextMenu {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { onOpenInNewWindow(url) }
            Button("Remove from List", systemImage: "minus.circle") { documents.forgetRecent(url) }
        }
    }

    @ViewBuilder
    private func fileMenu(_ node: LibraryNode) -> some View {
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { onOpenInNewWindow(node.url) }
        Button("Rename\u{2026}", systemImage: "pencil") { startRename(node) }
        Divider()
        Button("Delete\u{2026}", systemImage: "trash", role: .destructive) { deleteTarget = node }
    }

    @ViewBuilder
    private func folderMenu(_ node: LibraryNode) -> some View {
        Button("New Sheet in Group", systemImage: "square.and.pencil") { createSheet(in: node.url) }
        Button("New Group Inside\u{2026}", systemImage: "folder.badge.plus") {
            newGroupFolder = node.url
            showNewGroup = true
        }
        Button("Rename\u{2026}", systemImage: "pencil") { startRename(node) }
        Divider()
        Button("Delete\u{2026}", systemImage: "trash", role: .destructive) { deleteTarget = node }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                createSheet(in: nil)
            } label: {
                Label("New Sheet", systemImage: "square.and.pencil")
            }
            Menu {
                Button("New Sheet", systemImage: "square.and.pencil") { createSheet(in: nil) }
                Button("New Group\u{2026}", systemImage: "folder.badge.plus") {
                    newGroupFolder = nil
                    showNewGroup = true
                }
                .disabled(library.folderURL == nil)
                Button("Quick Open\u{2026}", systemImage: "magnifyingglass") { onQuickOpen() }
                Divider()
                Button("Open a Document\u{2026}", systemImage: "folder") { showDocumentPicker = true }
                Button(library.folderURL == nil ? "Choose Library Folder\u{2026}" : "Change Library Folder\u{2026}",
                       systemImage: "books.vertical") { showFolderPicker = true }
                if library.folderURL != nil {
                    Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                }
            } label: {
                Label("Library Options", systemImage: "ellipsis.circle")
            }
        }
    }

    /// While searching, the line that matched inside a sheet whose name didn't.
    private func matchSnippet(_ node: LibraryNode) -> String? {
        guard !query.isEmpty, node.name.range(of: query, options: .caseInsensitive) == nil else { return nil }
        return node.snippet(matching: query)
    }

    private var deleteTitle: String {
        guard let deleteTarget else { return "" }
        return deleteTarget.isFolder
            ? "Delete the group \u{201C}\(deleteTarget.name)\u{201D} and its \(deleteTarget.allFiles.count) sheets?"
            : "Delete \u{201C}\(deleteTarget.name)\u{201D}?"
    }

    // MARK: - Actions

    private func createSheet(in folder: URL?) {
        guard let url = documents.newDocumentURL(in: folder) else {
            errorMessage = "Couldn't create a new sheet there."
            return
        }
        onOpen(url, nil)
    }

    private func startRename(_ node: LibraryNode) {
        renameTarget = node
        renameText = node.name
    }

    private func renameNow() {
        guard let node = renameTarget else { return }
        renameTarget = nil
        let open = node.allFiles.compactMap { documents.document(at: $0.url) }
        open.forEach { $0.autosaveNow() }
        guard let newURL = library.rename(node, to: renameText) else {
            errorMessage = "Couldn't rename \u{201C}\(node.name)\u{201D}. Another item may already have that name."
            return
        }
        documents.filesMoved(from: node.url, to: newURL)
    }

    private func deleteNow() {
        guard let node = deleteTarget else { return }
        deleteTarget = nil
        documents.filesDeleted(node.url)
        library.trash(node)
    }
}

/// Indented rows of the nested tag tree.
private struct PadTagRows: View {
    let nodes: [LibraryModel.TagNode]
    let depth: Int
    let selected: String?
    let onSelect: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            Button {
                onSelect(node.path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "number").font(.caption).foregroundStyle(.secondary)
                    Text(node.name).lineLimit(1).foregroundStyle(Color.primary)
                    Spacer()
                    Text("\(node.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .padding(.leading, CGFloat(depth) * 16)
            }
            .listRowBackground(selected == node.path ? Color.accentColor.opacity(0.18) : nil)
            if let children = node.children {
                PadTagRows(nodes: children, depth: depth + 1, selected: selected, onSelect: onSelect)
            }
        }
    }
}
