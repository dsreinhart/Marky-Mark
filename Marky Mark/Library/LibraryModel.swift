//
//  LibraryModel.swift
//  Marky Mark
//
//  A folder of Markdown files shown as sheets and groups in the sidebar.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

nonisolated struct LibraryNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isFolder: Bool
    var children: [LibraryNode]?
    var wordCount: Int
    var keywords: [String]
    var modified: Date

    var id: URL { url }

    /// Every file below this node, depth first.
    var allFiles: [LibraryNode] {
        if isFolder { return (children ?? []).flatMap(\.allFiles) }
        return [self]
    }
}

@MainActor
@Observable
final class LibraryModel {
    static let shared = LibraryModel()

    private(set) var folderURL: URL?
    private(set) var root: LibraryNode?
    private(set) var isScanning = false
    var searchText = ""
    var selectedKeyword: String? = nil

    @ObservationIgnored private var monitors: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    private static let bookmarkKey = "libraryFolderBookmark"
    nonisolated private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                folderURL = url
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                }
                refresh()
            }
        }
        // Changes made while the app was in the background (Finder copies, other editors).
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    var allKeywords: [String] {
        guard let root else { return [] }
        var counts: [String: Int] = [:]
        for file in root.allFiles { for keyword in file.keywords { counts[keyword, default: 0] += 1 } }
        return counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
    }

    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || selectedKeyword != nil
    }

    /// Files matching the search text and keyword filter (flat list).
    var filteredFiles: [LibraryNode] {
        guard let root else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return root.allFiles.filter { node in
            if let keyword = selectedKeyword, !node.keywords.contains(keyword) { return false }
            if query.isEmpty { return true }
            return node.name.lowercased().contains(query) || node.keywords.contains { $0.lowercased().contains(query) }
        }
    }

    // MARK: - Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder that holds your Markdown library"
        panel.prompt = "Use as Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        folderURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        folderURL = url
        selectedKeyword = nil
        refresh()
    }

    func refresh() {
        guard let folderURL else { root = nil; return }
        refreshTask?.cancel()
        isScanning = true
        refreshTask = Task {
            let scanned = await Task.detached(priority: .utility) { Self.scan(folderURL, depth: 0) }.value
            guard !Task.isCancelled else { return }
            root = scanned
            isScanning = false
            startMonitoring(directories: Self.directories(in: scanned))
        }
    }

    nonisolated private static func directories(in node: LibraryNode) -> [URL] {
        guard node.isFolder else { return [] }
        return [node.url] + (node.children ?? []).flatMap(directories(in:))
    }

    nonisolated private static func scan(_ url: URL, depth: Int) -> LibraryNode {
        let fm = FileManager.default
        var children: [LibraryNode] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .nameKey]
        if depth < 6, let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for item in items {
                let values = try? item.resourceValues(forKeys: Set(keys))
                let modified = values?.contentModificationDate ?? .distantPast
                if values?.isDirectory == true {
                    let group = scan(item, depth: depth + 1)
                    children.append(group)
                } else if markdownExtensions.contains(item.pathExtension.lowercased()) {
                    let text = (try? String(contentsOf: item, encoding: .utf8)) ?? ""
                    let words = text.split { $0.isWhitespace || $0.isNewline }.count
                    children.append(LibraryNode(url: item, name: item.deletingPathExtension().lastPathComponent, isFolder: false,
                                                children: nil, wordCount: words, keywords: FrontMatter.keywords(in: text), modified: modified))
                }
            }
        }
        children.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return LibraryNode(url: url, name: url.lastPathComponent, isFolder: true, children: children,
                           wordCount: children.reduce(0) { $0 + $1.wordCount }, keywords: [], modified: modified)
    }

    /// Watches every directory of the library (a directory only reports changes to its own entries).
    private func startMonitoring(directories: [URL]) {
        monitors.forEach { $0.cancel() }
        monitors = []
        for url in directories.prefix(300) {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .rename, .delete, .attrib],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            monitors.append(source)
        }
    }

    @ObservationIgnored private var debounce: Task<Void, Never>?
    func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: - File operations

    /// Creates an empty sheet named "Untitled", "Untitled 2", … in the folder.
    func newSheet(in folder: URL? = nil) -> URL? {
        guard let base = folder ?? folderURL else { return nil }
        var candidate = base.appending(path: "Untitled.md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appending(path: "Untitled \(counter).md")
            counter += 1
        }
        do {
            try "".write(to: candidate, atomically: true, encoding: .utf8)
            scheduleRefresh()
            return candidate
        } catch {
            return nil
        }
    }

    func newGroup(in folder: URL? = nil, named name: String) -> Bool {
        guard let base = folder ?? folderURL else { return false }
        let url = base.appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            scheduleRefresh()
            return true
        } catch {
            return false
        }
    }

    func rename(_ node: LibraryNode, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var target = node.url.deletingLastPathComponent().appending(path: trimmed)
        if !node.isFolder, target.pathExtension.isEmpty { target = target.appendingPathExtension(node.url.pathExtension) }
        do {
            try FileManager.default.moveItem(at: node.url, to: target)
            scheduleRefresh()
            return target
        } catch {
            return nil
        }
    }

    func trash(_ node: LibraryNode) {
        try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        scheduleRefresh()
    }
}
