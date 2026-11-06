//
//  LibraryModel.swift
//  Markwright
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
    /// Lower-cased targets of `[[wiki links]]` in the file.
    var links: [String] = []
    /// The sheet's text, for full-text search.
    var body: String = ""
    var modified: Date

    var id: URL { url }

    /// The line around the first match of `query` in the text, trimmed for a sidebar caption.
    func snippet(matching query: String) -> String? {
        guard !query.isEmpty,
              let range = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let lineStart = body[..<range.lowerBound].lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
        let lineEnd = body[range.upperBound...].firstIndex(of: "\n") ?? body.endIndex
        var line = body[lineStart..<lineEnd]
        var prefix = ""
        let lead = body.distance(from: lineStart, to: range.lowerBound)
        if lead > 40 {
            line = line.dropFirst(lead - 40)
            prefix = "…"
        }
        let trimmed = String(line.prefix(120)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : prefix + trimmed
    }

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
            if let keyword = selectedKeyword,
               !node.keywords.contains(where: { $0 == keyword || $0.hasPrefix(keyword + "/") }) { return false }
            if query.isEmpty { return true }
            return node.name.lowercased().contains(query)
                || node.keywords.contains { $0.lowercased().contains(query) }
                || node.body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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

    nonisolated private static let tagRegex = try! NSRegularExpression(pattern: #"(?<=^|[\s(,])#([\p{L}\p{N}_/\-]*\p{L}[\p{L}\p{N}_/\-]*)"#, options: [.anchorsMatchLines])
    nonisolated private static let wikiRegex = try! NSRegularExpression(pattern: #"\[\[([^\]|\n]+)(\|[^\]\n]+)?\]\]"#)

    nonisolated static func inlineTags(in text: String) -> [String] {
        let ns = text as NSString
        var tags: [String] = []
        for match in tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var tag = ns.substring(with: match.range(at: 1))
            while tag.hasSuffix("/") || tag.hasSuffix("-") { tag.removeLast() }
            if !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
        }
        return tags
    }

    nonisolated private static func wikiTargets(in text: String) -> [String] {
        let ns = text as NSString
        var targets: [String] = []
        for match in wikiRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            if !target.isEmpty, !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    /// True when the file lives inside the library folder.
    func contains(_ url: URL) -> Bool {
        guard let folderURL else { return false }
        return url.standardizedFileURL.path.hasPrefix(folderURL.standardizedFileURL.path + "/")
    }

    // MARK: - Links & tags

    /// Sheets whose text links to the given file with `[[its name]]`.
    func backlinks(to url: URL?) -> [LibraryNode] {
        guard let url, let root else { return [] }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return root.allFiles.filter { $0.url.standardizedFileURL != url.standardizedFileURL && $0.links.contains(name) }
    }

    /// Sheet names for `[[` autocompletion.
    func sheetNames(matching partial: String) -> [String] {
        guard let root else { return [] }
        let query = partial.trimmingCharacters(in: .whitespaces).lowercased()
        let names = root.allFiles.map(\.name)
        let matches = query.isEmpty ? names : names.filter { $0.lowercased().contains(query) }
        return Array(matches.sorted { a, b in
            let aPrefix = a.lowercased().hasPrefix(query), bPrefix = b.lowercased().hasPrefix(query)
            if aPrefix != bPrefix { return aPrefix }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.prefix(12))
    }

    /// Keywords arranged by their `/` segments, with the number of sheets under each node.
    struct TagNode: Identifiable, Hashable {
        let path: String
        let name: String
        var count: Int
        var children: [TagNode]?
        var id: String { path }
    }

    var tagTree: [TagNode] {
        guard let root else { return [] }
        var counts: [String: Int] = [:]
        for file in root.allFiles {
            var seen: Set<String> = []
            for keyword in file.keywords {
                let parts = keyword.split(separator: "/").map(String.init)
                for depth in 1...max(parts.count, 1) {
                    let path = parts.prefix(depth).joined(separator: "/")
                    if seen.insert(path).inserted { counts[path, default: 0] += 1 }
                }
            }
        }
        func build(prefix: String) -> [TagNode] {
            let depth = prefix.isEmpty ? 1 : prefix.split(separator: "/").count + 1
            let paths = counts.keys.filter { path in
                let parts = path.split(separator: "/")
                return parts.count == depth && (prefix.isEmpty || path.hasPrefix(prefix + "/"))
            }
            return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
                let children = build(prefix: path)
                return TagNode(path: path, name: String(path.split(separator: "/").last ?? ""), count: counts[path] ?? 0,
                               children: children.isEmpty ? nil : children)
            }
        }
        return build(prefix: "")
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
                    let text = (try? TextFileFormat.read(from: item).text) ?? ""
                    let words = text.split { $0.isWhitespace || $0.isNewline }.count
                    var keywords = FrontMatter.keywords(in: text)
                    for tag in inlineTags(in: text) where !keywords.contains(tag) { keywords.append(tag) }
                    children.append(LibraryNode(url: item, name: item.deletingPathExtension().lastPathComponent, isFolder: false,
                                                children: nil, wordCount: words, keywords: keywords,
                                                links: wikiTargets(in: text), body: text, modified: modified))
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
