//
//  Document.swift
//  Markwright
//
//  One open document: its text, file, auto-save, untitled draft and version history.
//

import SwiftUI
import CryptoKit

struct DocumentVersion: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
    var label: String { date.formatted(date: .abbreviated, time: .shortened) }
}

@MainActor
@Observable
final class Document: Identifiable {
    let id: UUID
    var text: String
    private(set) var lastSavedText: String
    /// What the document contained when it was opened this session ("Revert to Last Opened").
    private(set) var openedText: String
    private(set) var fileURL: URL?
    private(set) var bookmarkData: Data?
    private(set) var hasUnsavedChanges = false
    private(set) var versions: [DocumentVersion] = []
    /// How the file is encoded on disk (BOM, line endings); restored on every save.
    var fileFormat = TextFileFormat()

    @ObservationIgnored private var autosaveTask: Task<Void, Never>? = nil
    @ObservationIgnored var onFileChange: (() -> Void)? = nil

    static let autosaveDelay: Duration = .seconds(1.5)
    /// Minimum spacing between automatic version snapshots.
    static let versionInterval: TimeInterval = 5 * 60
    static let maxVersions = 50

    init(id: UUID = UUID(), text: String = "", fileURL: URL? = nil, bookmarkData: Data? = nil) {
        self.id = id
        self.text = text
        self.fileURL = fileURL
        self.bookmarkData = bookmarkData
        self.lastSavedText = fileURL == nil ? "" : text
        self.openedText = text
        self.hasUnsavedChanges = text != lastSavedText
        if fileURL != nil { reloadVersions() }
    }

    var isUntitled: Bool { fileURL == nil }
    var title: String { fileURL?.lastPathComponent ?? "Untitled" }

    /// Key for per-document settings such as writing goals.
    var goalKey: String { fileURL?.standardizedFileURL.path ?? "untitled:\(id.uuidString)" }

    /// Keywords stored as `tags` in the document's front matter.
    var keywords: [String] { FrontMatter.keywords(in: text) }

    func setKeywords(_ keywords: [String]) {
        text = FrontMatter.settingKeywords(keywords, in: text)
        textDidChange()
    }

    /// The file was renamed or moved on disk (e.g. from the library sidebar).
    func fileMoved(to url: URL) {
        let oldKey = goalKey
        fileURL = url
        bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        GoalStore.shared.rename(from: oldKey, to: goalKey)
        reloadVersions()
        onFileChange?()
    }
    var windowTitle: String { hasUnsavedChanges ? "\(title) — Edited" : title }

    // MARK: - Opening

    /// Opens a file chosen by the user (open panel, Finder, drag).
    static func open(url: URL) throws -> Document {
        let (content, format) = try TextFileFormat.read(from: url)
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let document = Document(text: content, fileURL: url, bookmarkData: bookmark)
        document.fileFormat = format
        document.snapshot(content)
        return document
    }

    /// Re-opens a file from a session bookmark. Returns nil if it is gone or inaccessible.
    static func restore(bookmark: Data) -> Document? {
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &isStale)
            if url.path.contains("/.Trash/") || !FileManager.default.fileExists(atPath: url.path) { return nil }
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            let (content, format) = try TextFileFormat.read(from: url)
            var data = bookmark
            if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                data = fresh
            }
            let document = Document(text: content, fileURL: url, bookmarkData: data)
            document.fileFormat = format
            document.snapshot(content)
            return document
        } catch {
            return nil
        }
    }

    // MARK: - Editing & auto-save

    func textDidChange() {
        hasUnsavedChanges = text != lastSavedText
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard hasUnsavedChanges else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Document.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.autosaveNow()
        }
    }

    /// Persists pending changes without UI: to the file, or to a recovery draft when untitled.
    /// Returns false only when a titled document could not be written.
    @discardableResult
    func autosaveNow() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard hasUnsavedChanges else { return true }
        return isUntitled ? writeDraft() : save()
    }

    /// Writes to the document's own file. Returns false when untitled or the write fails.
    @discardableResult
    func save() -> Bool {
        guard let bookmarkData else { return false }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else { return false }
            defer { url.stopAccessingSecurityScopedResource() }
            if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                self.bookmarkData = fresh
            }
            snapshotBeforeOverwrite()
            try fileFormat.encode(text).write(to: url, options: .atomic)
            lastSavedText = text
            fileURL = url
            hasUnsavedChanges = false
            if LibraryModel.shared.contains(url) { LibraryModel.shared.scheduleRefresh() }
            return true
        } catch {
            print("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Save As: writes to a new location and adopts it as the document's file.
    func write(to url: URL) throws {
        try fileFormat.encode(text).write(to: url, options: .atomic)
        let oldKey = goalKey
        if fileURL == nil { openedText = text }   // a new file's baseline is what was first saved
        fileURL = url
        GoalStore.shared.rename(from: oldKey, to: goalKey)
        bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        lastSavedText = text
        hasUnsavedChanges = false
        removeDraft()
        reloadVersions()
        snapshot(text)
        onFileChange?()
    }

    // MARK: - Untitled drafts

    static var draftsFolder: URL {
        let folder = DocumentStore.supportFolder.appending(path: "Drafts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func draftURL(for id: UUID) -> URL {
        draftsFolder.appending(path: "\(id.uuidString).md")
    }

    static func loadDraft(id: UUID) -> String? {
        try? String(contentsOf: draftURL(for: id), encoding: .utf8)
    }

    private func writeDraft() -> Bool {
        do {
            try text.write(to: Self.draftURL(for: id), atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Could not save draft: \(error.localizedDescription)")
            return false
        }
    }

    func removeDraft() {
        try? FileManager.default.removeItem(at: Self.draftURL(for: id))
    }

    // MARK: - Versions

    private static func versionsFolder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return DocumentStore.supportFolder
            .appending(path: "Versions", directoryHint: .isDirectory)
            .appending(path: String(key), directoryHint: .isDirectory)
    }

    private var versionsFolder: URL? {
        fileURL.map { Self.versionsFolder(for: $0) }
    }

    private func reloadVersions() {
        guard let folder = versionsFolder,
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            versions = []
            return
        }
        versions = urls.compactMap { url -> DocumentVersion? in
            guard url.pathExtension == "md" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard let millis = Double(name) else { return nil }
            return DocumentVersion(url: url, date: Date(timeIntervalSince1970: millis / 1000))
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps the content that is about to be overwritten on disk, at most every few minutes.
    private func snapshotBeforeOverwrite() {
        guard let latest = versions.first else {
            snapshot(lastSavedText)
            return
        }
        if Date().timeIntervalSince(latest.date) >= Self.versionInterval {
            snapshot(lastSavedText)
        }
    }

    /// Stores `content` as a new version unless it matches the newest one.
    private func snapshot(_ content: String) {
        guard let folder = versionsFolder else { return }
        if let latest = versions.first, (try? String(contentsOf: latest.url, encoding: .utf8)) == content { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let millis = Int(Date().timeIntervalSince1970 * 1000)
            try content.write(to: folder.appending(path: "\(millis).md"), atomically: true, encoding: .utf8)
        } catch {
            print("Could not write version: \(error.localizedDescription)")
        }
        reloadVersions()
        for old in versions.dropFirst(Self.maxVersions) {
            try? FileManager.default.removeItem(at: old.url)
        }
        if versions.count > Self.maxVersions { reloadVersions() }
    }

    /// Explicit "Save a Version": snapshots the current text.
    func saveVersion() {
        snapshot(text)
    }

    func revert(to version: DocumentVersion) {
        guard let content = try? String(contentsOf: version.url, encoding: .utf8) else { return }
        snapshot(text)   // keep what we are leaving, so the revert itself can be undone
        text = content
        textDidChange()
    }

    func revertToOpened() {
        snapshot(text)
        text = openedText
        textDidChange()
    }
}
