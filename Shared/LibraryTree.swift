//
//  LibraryTree.swift
//  Markwright
//
//  The library's tree of groups and sheets for the Mac and iPad sidebars: groups open and close
//  through LibraryModel (one record for every window and tab), and rows take dropped library
//  items so sheets and groups can be dragged anywhere in the library.
//

import SwiftUI

/// The library's groups and sheets. Groups open and close through `LibraryModel`, so every
/// window and tab shows the same groups open and nothing else changes when one is clicked.
/// Each row takes drops: a group receives what is dropped on it, a sheet passes it to its group.
struct LibraryTree<Row: View>: View {
    let nodes: [LibraryNode]
    let row: (LibraryNode) -> Row
    let onDrop: ([URL], URL) -> Bool
    private var library = LibraryModel.shared

    init(nodes: [LibraryNode], row: @escaping (LibraryNode) -> Row, onDrop: @escaping ([URL], URL) -> Bool) {
        self.nodes = nodes
        self.row = row
        self.onDrop = onDrop
    }

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                DisclosureGroup(isExpanded: Binding(get: { library.isExpanded(node.url) },
                                                    set: { library.setExpanded(node.url, $0) })) {
                    LibraryTree(nodes: node.children ?? [], row: row, onDrop: onDrop)
                } label: {
                    LibraryDropTarget(folder: node.url, highlights: true, onDrop: onDrop) { row(node) }
                        .tag(node.url)
                }
            } else {
                LibraryDropTarget(folder: node.url.deletingLastPathComponent(), highlights: false, onDrop: onDrop) { row(node) }
                    .tag(node.url)
            }
        }
    }
}

/// A row that accepts dropped library items, outlined while something hovers over a group.
struct LibraryDropTarget<Content: View>: View {
    let folder: URL
    let highlights: Bool
    let onDrop: ([URL], URL) -> Bool
    @ViewBuilder let content: () -> Content
    @State private var targeted = false
    private var library = LibraryModel.shared

    init(folder: URL, highlights: Bool, onDrop: @escaping ([URL], URL) -> Bool, @ViewBuilder content: @escaping () -> Content) {
        self.folder = folder
        self.highlights = highlights
        self.onDrop = onDrop
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(highlights && targeted ? 1 : 0).padding(-3))
            .dropDestination(for: URL.self) { urls, _ in
                targeted = false
                return onDrop(urls, folder)
            } isTargeted: { targeted = $0 }
            .onChange(of: library.dropCount) { targeted = false }
    }
}

