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

    /// Starts access to a folder we were granted earlier. Returns false if there is no grant.
    @discardableResult
    static func begin(_ folder: URL) -> Bool {
        let path = normalized(folder)
        if active[path] != nil { return true }
        guard let data = bookmarks[path] else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return false }
        active[path] = url
        if stale, let fresh = try? url.bookmarkData() {
            var all = bookmarks
            all[path] = fresh
            bookmarks = all
        }
        return true
    }

    /// Remembers a folder the user just picked and starts accessing it.
    static func grant(_ folder: URL) {
        guard folder.startAccessingSecurityScopedResource() else { return }
        let path = normalized(folder)
        active[path] = folder
        if let data = try? folder.bookmarkData() {
            var all = bookmarks
            all[path] = data
            bookmarks = all
        }
    }
}

/// Folder picker opened at the document's own folder; the user confirms with "Open".
struct FolderPicker: UIViewControllerRepresentable {
    let startingAt: URL?
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.directoryURL = startingAt
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
