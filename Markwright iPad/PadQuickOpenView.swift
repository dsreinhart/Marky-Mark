//
//  PadQuickOpenView.swift
//  Markwright iPad
//
//  ⌘⇧O: type part of a name to show a sheet from the library or a document opened from Files.
//

import SwiftUI

struct PadQuickOpenView: View {
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool
    private var library = LibraryModel.shared
    private var documents = PadDocuments.shared

    init(onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
    }

    private struct Candidate: Identifiable {
        let url: URL
        let title: String
        let subtitle: String
        var id: String { Document.stablePath(url) }
    }

    private var candidates: [Candidate] {
        var seen: Set<String> = []
        var all: [Candidate] = []
        for file in library.root?.allFiles ?? [] {
            let candidate = Candidate(url: file.url, title: file.name,
                                      subtitle: file.url.deletingLastPathComponent().lastPathComponent + " \u{00B7} \(file.wordCount.formatted()) words")
            if seen.insert(candidate.id).inserted { all.append(candidate) }
        }
        for url in documents.recents {
            let candidate = Candidate(url: url, title: url.deletingPathExtension().lastPathComponent,
                                      subtitle: url.deletingLastPathComponent().lastPathComponent + " \u{00B7} opened from Files")
            if seen.insert(candidate.id).inserted { all.append(candidate) }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(all.prefix(40)) }
        return all.compactMap { candidate -> (Candidate, Int)? in
            guard let score = FuzzyMatch.score(q, in: candidate.title.lowercased()) else { return nil }
            return (candidate, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(40)
        .map(\.0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Open sheet\u{2026}", text: $query)
                        .font(.title3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .onSubmit { openHighlighted() }
                        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(candidates.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                }
                .padding(14)
                Divider()
                let items = candidates
                if items.isEmpty {
                    Text(library.folderURL == nil && documents.recents.isEmpty
                         ? "Choose a library folder in the sidebar to find its sheets here."
                         : "No matches")
                        .foregroundStyle(.secondary)
                        .padding(24)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        List(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                open(item.url)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).foregroundStyle(Color.primary)
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .listRowBackground(index == highlighted ? Color.accentColor.opacity(0.2) : nil)
                            .id(index)
                        }
                        .listStyle(.plain)
                        .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                    }
                }
            }
            .navigationTitle("Quick Open")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationSizing(.form)
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onAppear { fieldFocused = true }
    }

    private func openHighlighted() {
        let items = candidates
        guard !items.isEmpty else { return }
        open(items[min(highlighted, items.count - 1)].url)
    }

    private func open(_ url: URL) {
        dismiss()
        onOpen(url)
    }
}
