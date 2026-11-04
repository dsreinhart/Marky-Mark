//
//  LibraryView.swift
//  Marky Mark
//
//  The left sidebar: sheets and groups of the library folder, with search and
//  keyword filters. Clicking a sheet opens it in a tab.
//

import SwiftUI
import AppKit

struct LibraryView: View {
    let currentFileURL: URL?
    @State private var selection: URL? = nil
    @State private var renameTarget: LibraryNode? = nil
    @State private var renameText = ""
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    private var library = LibraryModel.shared

    init(currentFileURL: URL?) {
        self.currentFileURL = currentFileURL
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if library.folderURL == nil {
                emptyState
            } else {
                searchField
                if !library.allKeywords.isEmpty { keywordFilter }
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
            TextField("Search sheets", text: Binding(get: { library.searchText }, set: { library.searchText = $0 }))
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

    private var keywordFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(library.allKeywords, id: \.self) { keyword in
                    Button {
                        library.selectedKeyword = library.selectedKeyword == keyword ? nil : keyword
                    } label: {
                        Text(keyword)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(library.selectedKeyword == keyword ? Color.accentColor : Color.accentColor.opacity(0.15)))
                            .foregroundStyle(library.selectedKeyword == keyword ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var list: some View {
        if library.isFiltering {
            List(library.filteredFiles, selection: $selection) { node in
                row(node)
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, url in open(url) }
        } else if let root = library.root {
            List(root.children ?? [], children: \.children, selection: $selection) { node in
                row(node)
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, url in open(url) }
        }
    }

    private func row(_ node: LibraryNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "doc.text")
                .foregroundStyle(node.isFolder ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                if !node.isFolder {
                    Text("\(node.wordCount.formatted()) words" + (node.keywords.isEmpty ? "" : " · " + node.keywords.joined(separator: ", ")))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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

    // MARK: - Actions

    private func open(_ url: URL?) {
        guard let url, !url.hasDirectoryPath, let root = library.root,
              root.allFiles.contains(where: { $0.url == url }) else { return }
        guard url.standardizedFileURL != currentFileURL?.standardizedFileURL else { return }
        let store = DocumentStore.shared
        if let document = store.openDocument(at: url) {
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
