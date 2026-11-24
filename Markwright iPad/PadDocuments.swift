//
//  PadDocuments.swift
//  Markwright iPad
//
//  The documents open in any window, so two windows on one file share one copy, plus the
//  documents opened from outside the library (with the bookmarks that reopen them after a relaunch).
//

import SwiftUI
import UIKit

@MainActor
@Observable
final class PadDocuments {
    static let shared = PadDocuments()

    /// Open documents by `Document.stablePath`.
    private var open: [String: Document] = [:]
    /// Files opened from Files or elsewhere outside the library, newest first.
    private(set) var recents: [URL] = []
    @ObservationIgnored private var recentBookmarks: [String: Data] = [:]
    @ObservationIgnored private var accessing: Set<String> = []
    private static let recentsKey = "pad.recentDocuments"
    private static let maxRecents = 15

    private init() {
        let stored = (UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data]) ?? []
        for data in stored {
            var stale = false
            guard let url = try? FileBookmark.resolve(data, isStale: &stale) else { continue }
            let key = Document.stablePath(url)
            recentBookmarks[key] = stale ? (FileBookmark.make(url) ?? data) : data
            recents.append(url)
        }
    }

    var documents: [Document] { Array(open.values) }

    func document(at url: URL) -> Document? { open[Document.stablePath(url)] }

    // MARK: - Opening

    enum OpenError: LocalizedError {
        case noAccess(String)
        var errorDescription: String? {
            switch self {
            case .noAccess(let name):
                "Markwright no longer has access to \u{201C}\(name)\u{201D}. Open it again from Files, or choose its folder as the library."
            }
        }
    }

    /// The document for a file, read on first use. A file still in iCloud is downloaded first.
    func document(for url: URL) async throws -> Document {
        if let existing = document(at: url) { return existing }
        guard startAccess(url) else { throw OpenError.noAccess(url.lastPathComponent) }
        let (content, format) = try await Task.detached(priority: .userInitiated) { try TextFileIO.read(url) }.value
        if let existing = document(at: url) { return existing }
        let document = Document.opened(url: url, content: content, format: format)
        open[Document.stablePath(url)] = document
        return document
    }

    /// A file handed over by Files ("Open in Markwright", or the Open window): remember it.
    func noteOpenedFromOutside(_ url: URL) {
        let key = Document.stablePath(url)
        if !accessing.contains(key), url.startAccessingSecurityScopedResource() { accessing.insert(key) }
        guard !LibraryModel.shared.contains(url) else { return }
        if let data = FileBookmark.make(url) { recentBookmarks[key] = data }
        recents.removeAll { Document.stablePath($0) == key }
        recents.insert(url, at: 0)
        if recents.count > Self.maxRecents { recents = Array(recents.prefix(Self.maxRecents)) }
        saveRecents()
    }

    func forgetRecent(_ url: URL) {
        let key = Document.stablePath(url)
        recents.removeAll { Document.stablePath($0) == key }
        recentBookmarks[key] = nil
        saveRecents()
    }

    private func saveRecents() {
        let data = recents.compactMap { recentBookmarks[Document.stablePath($0)] }
        UserDefaults.standard.set(data, forKey: Self.recentsKey)
    }

    /// Makes a file readable: through the library folder, a folder allowed for images, the file's
    /// own bookmark from an earlier session, or the access Files handed over with it.
    @discardableResult
    func startAccess(_ url: URL) -> Bool {
        let key = Document.stablePath(url)
        if accessing.contains(key) || LibraryModel.shared.contains(url) { return true }
        if PadFolderAccess.begin(url.deletingLastPathComponent()) { return true }
        if let data = recentBookmarks[key] {
            var stale = false
            if let resolved = try? FileBookmark.resolve(data, isStale: &stale), resolved.startAccessingSecurityScopedResource() {
                accessing.insert(key)
                return true
            }
        }
        if url.startAccessingSecurityScopedResource() {
            accessing.insert(key)
            return true
        }
        // Inside the app's own folder no access is needed.
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    // MARK: - New, rename, delete

    /// A new empty sheet: in the library when there is one, otherwise in Markwright's folder in Files.
    func newDocumentURL(in folder: URL? = nil) -> URL? {
        if let url = LibraryModel.shared.newSheet(in: folder) { return url }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        var candidate = documents.appending(path: "Untitled.md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = documents.appending(path: "Untitled \(counter).md")
            counter += 1
        }
        return (try? TextFileIO.write(Data(), to: candidate)) != nil ? candidate : nil
    }

    /// Renames the document's file, keeping its extension. Returns the new location.
    func rename(_ document: Document, to newName: String) throws -> URL? {
        guard let old = document.fileURL else { return nil }
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, name != old.deletingPathExtension().lastPathComponent else { return nil }
        if name.hasPrefix(".") { name = "-" + name.dropFirst() }
        let target = old.deletingLastPathComponent().appending(path: name).appendingPathExtension(old.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        document.autosaveNow()
        try TextFileIO.move(old, to: target)
        filesMoved(from: old, to: target)
        if LibraryModel.shared.contains(target) { LibraryModel.shared.scheduleRefresh() }
        return target
    }

    /// A file or folder was renamed or moved (here or from the library): open documents follow it.
    func filesMoved(from old: URL, to new: URL) {
        let oldPath = Document.stablePath(old)
        for (path, document) in open {
            var moved: URL? = nil
            if path == oldPath {
                moved = new
            } else if path.hasPrefix(oldPath + "/") {
                moved = new.appending(path: String(path.dropFirst(oldPath.count + 1)))
            }
            guard let moved else { continue }
            open[path] = nil
            document.fileMoved(to: moved)
            open[Document.stablePath(moved)] = document
            if let index = recents.firstIndex(where: { Document.stablePath($0) == path }) {
                recents[index] = moved
                recentBookmarks[path] = nil
                if let data = FileBookmark.make(moved) { recentBookmarks[Document.stablePath(moved)] = data }
                saveRecents()
            }
        }
        NotificationCenter.default.post(name: .padFileMoved, object: nil, userInfo: ["old": old, "new": new])
    }

    /// A file or folder was deleted: its open documents stop being tracked.
    func filesDeleted(_ url: URL) {
        let gone = Document.stablePath(url)
        for path in open.keys where path == gone || path.hasPrefix(gone + "/") {
            open[path] = nil
        }
        NotificationCenter.default.post(name: .padFileDeleted, object: nil, userInfo: ["url": url])
    }

    /// Saves every open document (the app is going to the background).
    func saveAll() {
        for document in open.values { document.autosaveNow() }
    }
}

extension Notification.Name {
    /// userInfo "old" and "new": windows showing the old file switch to the new one.
    static let padFileMoved = Notification.Name("PadFileMoved")
    /// userInfo "url": windows showing that file (or a file inside it) close it.
    static let padFileDeleted = Notification.Name("PadFileDeleted")
}
