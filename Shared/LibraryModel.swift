//
//  LibraryModel.swift
//  Markwright
//
//  A folder of Markdown files shown as sheets and groups in the sidebar. Shared by the Mac and
//  the iPad; choosing the folder is done by each app's own folder window.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    /// Counts finished drops, so every row clears its drop outline (a row the drag only passed
    /// over doesn't always hear that the drag left it).
    private(set) var dropCount = 0

    @ObservationIgnored private var monitors: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    private static let bookmarkKey = "libraryFolderBookmark"
    nonisolated private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? FileBookmark.resolve(data, isStale: &stale),
               url.startAccessingSecurityScopedResource() {
                folderURL = url
                if stale, let fresh = FileBookmark.make(url) {
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                }
                refresh()
            }
        }
        // Changes made while the app was in the background (Finder copies, other editors).
        #if os(macOS)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        #else
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        #endif
        activationObserver = NotificationCenter.default.addObserver(forName: didBecomeActive,
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

    func setFolder(_ url: URL) {
        if let data = FileBookmark.make(url) {
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
        // Hidden files are listed too, for iCloud's placeholders of files not yet on this device.
        if depth < 6, let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) {
            for item in items {
                if let placeholder = iCloudPlaceholderTarget(item) {
                    try? fm.startDownloadingUbiquitousItem(at: placeholder)
                    guard markdownExtensions.contains(placeholder.pathExtension.lowercased()) else { continue }
                    children.append(LibraryNode(url: placeholder, name: placeholder.deletingPathExtension().lastPathComponent,
                                                isFolder: false, children: nil, wordCount: 0, keywords: [],
                                                modified: .distantPast))
                    continue
                }
                if item.lastPathComponent.hasPrefix(".") { continue }
                let values = try? item.resourceValues(forKeys: Set(keys))
                let modified = values?.contentModificationDate ?? .distantPast
                if values?.isDirectory == true {
                    let group = scan(item, depth: depth + 1)
                    // A sheet's picture folder ("Trip-images") isn't a group: hide it unless it holds sheets.
                    if group.name.hasSuffix("-images"), group.allFiles.isEmpty { continue }
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

    /// For iCloud's ".Name.md.icloud" stand-in of a file still in the cloud, the file it stands for.
    nonisolated static func iCloudPlaceholderTarget(_ item: URL) -> URL? {
        let name = item.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".x.icloud".count else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return item.deletingLastPathComponent().appending(path: real)
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
            try TextFileIO.write(Data(), to: candidate)
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
        // A dot alone doesn't make an extension: "Notes v1.2" is still a Markdown sheet.
        if !node.isFolder, !Self.markdownExtensions.contains(target.pathExtension.lowercased()) {
            target = target.appendingPathExtension(node.url.pathExtension)
        }
        do {
            try TextFileIO.move(node.url, to: target)
            carryOver(from: node, to: target)
            moveExpansion(from: node.url, to: target)
            scheduleRefresh()
            return target
        } catch {
            return nil
        }
    }

    /// Version history and goals are stored by path, for every sheet at or below a renamed item.
    private func carryOver(from node: LibraryNode, to target: URL) {
        let oldPath = Document.stablePath(node.url)
        for file in node.allFiles {
            let path = Document.stablePath(file.url)
            let moved = path == oldPath ? target : target.appending(path: String(path.dropFirst(oldPath.count + 1)))
            Document.moveVersions(from: file.url, to: moved)
            GoalStore.shared.rename(from: path, to: Document.stablePath(moved))
        }
    }

    // MARK: - Moving

    enum MoveError: LocalizedError {
        case intoItself(String)
        case nameTaken(String, folder: String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .intoItself(let name): return "\u{201C}\(name)\u{201D} can't go inside itself."
            case .nameTaken(let name, let folder): return "There's already an item named \u{201C}\(name)\u{201D} in \u{201C}\(folder)\u{201D}."
            case .failed(let detail): return detail
            }
        }
    }

    /// Moves a sheet or group into `folder` (the library folder or a group in it), taking along
    /// the sheet's "<Name>-images" picture folder, its versions, goal, expanded state and open tabs
    /// (`onMoved` is called for each moved item so the app can retarget open documents).
    /// Returns the new URL, nil when nothing needed to move (already there).
    @discardableResult
    func move(_ source: URL, into folder: URL, onMoved: (URL, URL) -> Void = { _, _ in }) throws -> URL? {
        let fm = FileManager.default
        let sourcePath = Document.stablePath(source), folderPath = Document.stablePath(folder)
        let name = source.lastPathComponent
        if Document.stablePath(source.deletingLastPathComponent()) == folderPath { return nil }
        if folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
            throw MoveError.intoItself(source.deletingPathExtension().lastPathComponent)
        }
        let folderName = folderURL.map { Document.stablePath($0) } == folderPath ? (folderURL?.lastPathComponent ?? "") : folder.lastPathComponent
        var isDirectory: ObjCBool = false
        let isGroup = fm.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let target = folder.appending(path: name, directoryHint: isGroup ? .isDirectory : .notDirectory)
        guard !fm.fileExists(atPath: target.path) else { throw MoveError.nameTaken(name, folder: folderName) }

        // The sheet's own picture folder, when its text links into it.
        var pictures: (folder: URL, shared: Bool)? = nil
        if !isGroup {
            let own = ImageFolderLinks.folderName(forDocumentNamed: source.deletingPathExtension().lastPathComponent)
            let ownURL = source.deletingLastPathComponent().appending(path: own, directoryHint: .isDirectory)
            let text = (try? TextFileFormat.read(from: source).text) ?? ""
            var dir: ObjCBool = false
            if ImageFolderLinks.references(text, folder: own), fm.fileExists(atPath: ownURL.path, isDirectory: &dir), dir.boolValue {
                if fm.fileExists(atPath: folder.appending(path: own).path) {
                    throw MoveError.nameTaken(own, folder: folderName)
                }
                pictures = (ownURL, Self.otherSheet(in: source.deletingLastPathComponent(), besides: source, linksTo: own))
            }
        }

        let movedNode = root.flatMap { Self.find(source, in: $0) }
        do {
            try TextFileIO.move(source, to: target)
        } catch {
            throw MoveError.failed("Couldn't move \u{201C}\(name)\u{201D}: \(error.localizedDescription)")
        }
        if let movedNode { carryOver(from: movedNode, to: target) }
        moveExpansion(from: source, to: target)
        onMoved(source, target)

        if let pictures {
            let destination = folder.appending(path: pictures.folder.lastPathComponent, directoryHint: .isDirectory)
            if pictures.shared {
                // Another sheet beside it uses this folder too: copy just this sheet's pictures.
                let text = (try? TextFileFormat.read(from: target).text) ?? ""
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for file in ImageFolderLinks.linkedFiles(in: text, folder: pictures.folder.lastPathComponent) {
                    let from = pictures.folder.appending(path: file)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    try? fm.copyItem(at: from, to: destination.appending(path: file))
                }
            } else {
                try? TextFileIO.move(pictures.folder, to: destination)
                moveExpansion(from: pictures.folder, to: destination)
            }
        }
        setExpanded(folder, true)
        dropCount += 1
        scheduleRefresh()
        return target
    }

    /// Whether another Markdown file in `directory` links into the picture folder `pictureFolder`.
    private static func otherSheet(in directory: URL, besides sheet: URL, linksTo pictureFolder: String) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.contains { item in
            item.standardizedFileURL != sheet.standardizedFileURL
                && markdownExtensions.contains(item.pathExtension.lowercased())
                && ImageFolderLinks.references((try? TextFileFormat.read(from: item).text) ?? "", folder: pictureFolder)
        }
    }

    /// Where `url` could be moved: the top level and every group, minus its own folder, itself
    /// and anything inside it. Picture folders aren't in the tree, so they aren't offered. `depth` indents the group's name in a menu.
    func moveDestinations(for url: URL) -> [(url: URL, name: String, depth: Int)] {
        guard let root else { return [] }
        let path = Document.stablePath(url), parent = Document.stablePath(url.deletingLastPathComponent())
        var result: [(URL, String, Int)] = []
        func walk(_ node: LibraryNode, depth: Int) {
            let nodePath = Document.stablePath(node.url)
            if nodePath == path || nodePath.hasPrefix(path + "/") { return }
            if nodePath != parent { result.append((node.url, depth == 0 ? "Top Level" : node.name, depth)) }
            for child in node.children ?? [] where child.isFolder { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return result
    }

    static func find(_ url: URL, in node: LibraryNode) -> LibraryNode? {
        if Document.stablePath(node.url) == Document.stablePath(url) { return node }
        for child in node.children ?? [] {
            if let found = find(url, in: child) { return found }
        }
        return nil
    }

    // MARK: - Expanded groups

    /// Groups open in the sidebar, by path inside the library folder. One set for every window
    /// and tab, so clicking in one never changes what another shows open.
    private(set) var expandedGroups: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "library.expandedGroups") ?? [])

    private func relativePath(_ url: URL) -> String? {
        guard let folderURL else { return nil }
        let base = Document.stablePath(folderURL), path = Document.stablePath(url)
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    func isExpanded(_ url: URL) -> Bool {
        relativePath(url).map(expandedGroups.contains) ?? false
    }

    func setExpanded(_ url: URL, _ expanded: Bool) {
        guard let key = relativePath(url), !key.isEmpty, expandedGroups.contains(key) != expanded else { return }
        if expanded { expandedGroups.insert(key) } else { expandedGroups.remove(key) }
        saveExpanded()
    }

    /// A moved or renamed group keeps its own open state and that of the groups inside it.
    private func moveExpansion(from old: URL, to new: URL) {
        guard let oldKey = relativePath(old), let newKey = relativePath(new), !oldKey.isEmpty else { return }
        var changed = false
        for key in expandedGroups where key == oldKey || key.hasPrefix(oldKey + "/") {
            expandedGroups.remove(key)
            expandedGroups.insert(newKey + key.dropFirst(oldKey.count))
            changed = true
        }
        if changed { saveExpanded() }
    }

    private func saveExpanded() {
        UserDefaults.standard.set(expandedGroups.sorted(), forKey: "library.expandedGroups")
    }

    func trash(_ node: LibraryNode) {
        #if os(macOS)
        try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        #else
        TextFileIO.delete(node.url)
        #endif
        scheduleRefresh()
    }
}
