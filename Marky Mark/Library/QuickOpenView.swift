//
//  QuickOpenView.swift
//  Marky Mark
//
//  ⌘⇧O: type part of a name to jump to a sheet in the library or an open tab.
//

import SwiftUI

struct QuickOpenView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    private var library = LibraryModel.shared
    private var store = DocumentStore.shared

    init() {}

    private struct Candidate: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let url: URL?
        let documentID: UUID?
    }

    private var candidates: [Candidate] {
        var seen: Set<String> = []
        var all: [Candidate] = []
        for document in store.documents {
            let key = document.fileURL?.standardizedFileURL.path ?? document.id.uuidString
            seen.insert(key)
            all.append(Candidate(id: key, title: document.title, subtitle: "Open tab", url: document.fileURL, documentID: document.id))
        }
        for file in library.root?.allFiles ?? [] {
            let key = file.url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            let folder = file.url.deletingLastPathComponent().lastPathComponent
            all.append(Candidate(id: key, title: file.name, subtitle: folder + " · \(file.wordCount.formatted()) words", url: file.url, documentID: nil))
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(all.prefix(40)) }
        return all.compactMap { candidate -> (Candidate, Int)? in
            guard let score = Self.fuzzyScore(q, in: candidate.title.lowercased()) else { return nil }
            return (candidate, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(40)
        .map(\.0)
    }

    /// Subsequence match with a bonus for consecutive and word-start hits.
    private static func fuzzyScore(_ query: String, in text: String) -> Int? {
        var score = 0
        var index = text.startIndex
        var previous: String.Index? = nil
        for char in query {
            guard let found = text[index...].firstIndex(of: char) else { return nil }
            score += 1
            if let previous, text.index(after: previous) == found { score += 3 }
            if found == text.startIndex || text[text.index(before: found)] == " " { score += 2 }
            previous = found
            index = text.index(after: found)
        }
        return score
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open sheet…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { openHighlighted() }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(candidates.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
            }
            .padding(12)
            Divider()
            let items = candidates
            if items.isEmpty {
                Text(library.folderURL == nil ? "Choose a library folder in the sidebar to search its sheets." : "No matches")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Image(systemName: item.documentID != nil ? "macwindow" : "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .listRowBackground(index == highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
                        .onTapGesture { open(item) }
                        .id(index)
                    }
                    .listStyle(.plain)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }
            }
        }
        .frame(width: 480, height: 360)
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func openHighlighted() {
        let items = candidates
        guard !items.isEmpty else { return }
        open(items[min(highlighted, items.count - 1)])
    }

    private func open(_ candidate: Candidate) {
        if let id = candidate.documentID, let document = store.document(id: id) {
            store.show(document)
        } else if let url = candidate.url, let document = store.openDocument(at: url) {
            store.show(document)
        }
        dismiss()
    }
}
