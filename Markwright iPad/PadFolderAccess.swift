//
//  PadFolderAccess.swift
//  Markwright iPad
//
//  Documents opened from Files only grant access to the file itself. To save images
//  beside a document we ask once for its folder and keep a security-scoped bookmark.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum PadFolderAccess {
    private static let key = "folderBookmarks"
    private static var active: [String: URL] = [:]

    private static var bookmarks: [String: Data] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static func normalized(_ folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Starts access to a folder we were granted earlier, or to one of its parent folders
    /// (a grant covers everything inside it). Returns false if there is no grant.
    @discardableResult
    static func begin(_ folder: URL) -> Bool {
        let path = normalized(folder)
        if active.keys.contains(where: { covers($0, path) }) { return true }
        let all = bookmarks
        // The closest granted folder first.
        for granted in all.keys.filter({ covers($0, path) }).sorted(by: { $0.count > $1.count }) {
            guard let data = all[granted] else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
                PadDiagnostics.log("bookmark for \(granted) no longer resolves")
                continue
            }
            guard url.startAccessingSecurityScopedResource() else {
                PadDiagnostics.log("bookmark for \(granted) resolved but access was refused")
                continue
            }
            active[granted] = url
            if stale, let fresh = try? url.bookmarkData() {
                var updated = bookmarks
                updated[granted] = fresh
                bookmarks = updated
            }
            return true
        }
        return false
    }

    enum GrantResult {
        case granted
        /// iPadOS didn't hand out access for the picked folder.
        case refused
    }

    /// Remembers a folder the user just picked and starts accessing it.
    @discardableResult
    static func grant(_ folder: URL) -> GrantResult {
        let path = normalized(folder)
        guard folder.startAccessingSecurityScopedResource() else {
            PadDiagnostics.log("grant \(path): startAccessingSecurityScopedResource returned false")
            return .refused
        }
        active[path] = folder
        do {
            let data = try folder.bookmarkData()
            var all = bookmarks
            all[path] = data
            bookmarks = all
            PadDiagnostics.log("grant \(path): access started, bookmark saved (\(data.count) bytes)")
        } catch {
            // Access still works for this session; it just won't be remembered.
            PadDiagnostics.log("grant \(path): access started, bookmark failed: \(error)")
        }
        return .granted
    }

    /// True when a grant for `picked` reaches `folder` (the same folder or one inside it).
    static func grant(_ picked: URL, covers folder: URL) -> Bool {
        covers(normalized(picked), normalized(folder))
    }

    private static func covers(_ granted: String, _ path: String) -> Bool {
        path == granted || path.hasPrefix(granted.hasSuffix("/") ? granted : granted + "/")
    }
}

/// A short log of folder-access and image-saving steps in Library/Caches, so a failure on a
/// device can be read back afterwards.
enum PadDiagnostics {
    nonisolated static func log(_ line: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = caches.appending(path: "Diagnostics.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// The system folder window, opened at the document's own folder; the user confirms with "Open".
struct FolderPicker: UIViewControllerRepresentable {
    let startingAt: URL?
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.directoryURL = startingAt
        PadDiagnostics.log("folder window opening at \(startingAt?.path ?? "nil")")
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}
