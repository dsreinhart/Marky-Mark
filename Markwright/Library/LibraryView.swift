//
//  LibraryView.swift
//  Markwright
//
//  The left sidebar: sheets and groups of the library folder, with search and
//  keyword filters. Clicking a sheet opens it in a tab.
//

import SwiftUI
import AppKit

struct LibraryView: View {
    let currentFileURL: URL?
    /// Live text of the sheet in this window, for the match count.
    let currentText: String
    /// Moves to the next (false) or previous (true) match of the query in this window's sheet.
    let onNavigateMatch: ((String, Bool) -> Void)?
    @State private var selection: URL? = nil
    @State private var renameTarget: LibraryNode? = nil
    @State private var renameText = ""
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    private var library = LibraryModel.shared

    init(currentFileURL: URL?, currentText: String = "", onNavigateMatch: ((String, Bool) -> Void)? = nil) {
        self.currentFileURL = currentFileURL
        self.currentText = currentText
        self.onNavigateMatch = onNavigateMatch
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if library.folderURL == nil {
                emptyState
            } else {
                searchField
                if !library.tagTree.isEmpty { tagFilter }
                Divider()
                list
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selection = currentFileURL }
        .onChange(of: currentFileURL) { _, url in selection = url }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let node = renameTarget, let newURL = library.rename(node, to: renameText),
                   let document = DocumentStore.shared.document(for: node.url) {
                    document.fileMoved(to: newURL)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { _ = library.newGroup(named: newGroupName); newGroupName = "" }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical").foregroundStyle(.secondary)
            Text(library.folderURL?.lastPathComponent ?? "Library")
                .font(.headline)
                .lineLimit(1)
            if library.isScanning {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Menu {
                Button("New Sheet") { createSheet() }
                Button("New Group…") { showNewGroup = true }
                Divider()
                Button("Choose Library Folder…") { library.chooseFolder() }
                if let url = library.folderURL {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Refresh") { library.refresh() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Choose a folder to use as your library. Its Markdown files become sheets and its subfolders become groups.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Folder…") { library.chooseFolder() }
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search sheets and text", text: Binding(get: { library.searchText }, set: { library.searchText = $0 }))
                .textFieldStyle(.plain)
            if !library.searchText.isEmpty {
                Button { library.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @AppStorage("library.tagsExpanded") private var tagsExpanded = true

    private var tagFilter: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $tagsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TagRows(nodes: library.tagTree, depth: 0, selected: library.selectedKeyword) { path in
                            library.selectedKeyword = library.selectedKeyword == path ? nil : path
                        }
                    }
                }
                .frame(maxHeight: 180)
            } label: {
                HStack {
                    Text("Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let selected = library.selectedKeyword {
                        Spacer()
                        Button {
                            library.selectedKeyword = nil
                        } label: {
                            Label("Clear #\(selected)", systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon).font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop filtering by #\(selected) and show every sheet in the folder")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    /// "2 sheets tagged #test/alpha", "1 sheet matching “plan”", or both, while a filter is on.
    private var filterSummary: String {
        let count = library.filteredFiles.count
        var text = count == 1 ? "1 sheet" : "\(count) sheets"
        let query = library.searchText.trimmingCharacters(in: .whitespaces)
        if let keyword = library.selectedKeyword { text += " tagged #\(keyword)" }
        if !query.isEmpty { text += (library.selectedKeyword == nil ? " matching “" : " and matching “") + query + "”" }
        return text
    }

    /// "3 matches in this sheet" with previous / next buttons, while the search term occurs here.
    @ViewBuilder
    private var matchNavigator: some View {
        let query = library.searchText.trimmingCharacters(in: .whitespaces)
        let count = query.isEmpty ? 0 : RichEditorController.matchCount(of: query, in: currentText)
        if count > 0, let onNavigateMatch {
            HStack(spacing: 6) {
                Text(count == 1 ? "1 match in this sheet" : "\(count) matches in this sheet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { onNavigateMatch(query, true) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⌘⇧G)")
                Button { onNavigateMatch(query, false) } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var list: some View {
        if library.isFiltering {
            VStack(alignment: .leading, spacing: 0) {
                Text(filterSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .help(library.selectedKeyword == nil
                          ? "Only sheets whose name or keywords match the search are listed."
                          : "Only sheets carrying this tag (or a tag nested under it) are listed. Clear the tag to see the whole folder again.")
                matchNavigator
                Divider()
                let openMatches = openTabMatches
                List(selection: $selection) {
                    ForEach(library.filteredFiles) { node in searchRow(node) }
                    if !openMatches.isEmpty {
                        Section("Open Tabs") {
                            ForEach(openMatches) { node in searchRow(node) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        } else if let root = library.root {
            List(root.children ?? [], children: \.children, selection: $selection) { node in
                row(node)
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, url in open(url) }
        }
    }

    /// A search result: clicking it opens the sheet and jumps to the match, even when it is
    /// already the selected row (the current sheet), which a selection change alone would miss.
    private func searchRow(_ node: LibraryNode) -> some View {
        row(node)
            .contentShape(Rectangle())
            .onTapGesture {
                selection = node.url
                open(node.url)
            }
    }

    private func row(_ node: LibraryNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "doc.text")
                .foregroundStyle(node.isFolder ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                if !node.isFolder {
                    if let snippet = matchSnippet(node) {
                        Text(snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(node.wordCount.formatted()) words" + (node.keywords.isEmpty ? "" : " · " + node.keywords.joined(separator: ", ")))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .tag(node.url)
        .contextMenu {
            if node.isFolder {
                Button("New Sheet in Group") { createSheet(in: node.url) }
            } else {
                Button("Open in New Tab") { open(node.url) }
            }
            Button("Rename…") { renameTarget = node; renameText = node.isFolder ? node.name : node.url.lastPathComponent }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { library.trash(node) }
        }
    }

    /// While searching, the line that matched inside a sheet whose name didn't.
    private func matchSnippet(_ node: LibraryNode) -> String? {
        let query = library.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, node.name.range(of: query, options: .caseInsensitive) == nil else { return nil }
        return node.snippet(matching: query)
    }

    // MARK: - Actions

    /// Open documents outside the library whose title or text matches the search, so a search
    /// also finds what is on screen (the help guide, files opened from elsewhere).
    private var openTabMatches: [LibraryNode] {
        let query = library.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return DocumentStore.shared.documents.compactMap { document in
            guard let url = document.fileURL, !library.contains(url) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.range(of: query, options: options) != nil || document.text.range(of: query, options: options) != nil else { return nil }
            var keywords = FrontMatter.keywords(in: document.text)
            for tag in LibraryModel.inlineTags(in: document.text) where !keywords.contains(tag) { keywords.append(tag) }
            return LibraryNode(url: url, name: name, isFolder: false, children: nil,
                               wordCount: TextStatistics.compute(markdown: document.text).words,
                               keywords: keywords, body: document.text, modified: Date())
        }
    }

    private func open(_ url: URL?) {
        guard let url, !url.hasDirectoryPath else { return }
        let store = DocumentStore.shared
        let inLibrary = library.root?.allFiles.contains(where: { $0.url == url }) ?? false
        guard inLibrary || store.document(for: url) != nil else { return }
        let query = library.searchText.trimmingCharacters(in: .whitespaces)
        if url.standardizedFileURL == currentFileURL?.standardizedFileURL {
            // Already showing: just go to the match.
            if !query.isEmpty, let document = store.document(for: url) { document.pendingJump = .init(text: query) }
            return
        }
        if let document = store.openDocument(at: url) {
            if !query.isEmpty { document.pendingJump = .init(text: query) }
            store.show(document)
        }
        // The file opened in its own tab; this tab's sidebar keeps pointing at this tab's document.
        Task { @MainActor in
            selection = currentFileURL
        }
    }

    private func createSheet(in folder: URL? = nil) {
        guard let url = library.newSheet(in: folder) else { return }
        let store = DocumentStore.shared
        if let document = store.openDocument(at: url) {
            store.show(document)
        }
    }
}


/// Indented rows of the nested tag tree.
private struct TagRows: View {
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
                    Image(systemName: "number").font(.caption2).foregroundStyle(.secondary)
                    Text(node.name).font(.callout).lineLimit(1)
                    Spacer()
                    Text("\(node.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                .padding(.leading, CGFloat(depth) * 14 + 4)
                .padding(.trailing, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected == node.path ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tooltip(for: node))
            if let children = node.children {
                TagRows(nodes: children, depth: depth + 1, selected: selected, onSelect: onSelect)
            }
        }
    }

    private func tooltip(for node: LibraryModel.TagNode) -> String {
        let sheets = node.count == 1 ? "1 sheet is" : "\(node.count) sheets are"
        let nested = node.children == nil ? "" : ", counting sub-tags"
        let action = selected == node.path ? "Click to clear the filter." : "Click to list only those sheets."
        return "\(sheets) tagged #\(node.path)\(nested). \(action)"
    }
}
