//
//  SupportFolder.swift
//  Markwright
//
//  Markwright's own storage inside its container (versions, drafts, the Help copy), and the
//  bookmark and file-access calls that differ between the Mac and the iPad.
//

import Foundation

enum SupportFolder {
    /// Lets tests point the app's storage at a scratch folder.
    nonisolated(unsafe) static var override: URL? = nil

    static var url: URL {
        let base = override
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = override ?? base.appending(path: "Markwright", directoryHint: .isDirectory)
        let fm = FileManager.default
        // Drafts and versions written under the app's earlier name move over once.
        let legacy = base.appending(path: "Marky Mark", directoryHint: .isDirectory)
        if override == nil, !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: folder)
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Bookmarks that reopen a file or folder in a later session. The Mac needs security-scoped
/// bookmarks; on the iPad a plain bookmark of a URL the person picked carries the access.
nonisolated enum FileBookmark {
    static func make(_ url: URL) -> Data? {
        #if os(macOS)
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try? url.bookmarkData()
        #endif
    }

    static func resolve(_ data: Data, isStale: inout Bool) throws -> URL {
        #if os(macOS)
        try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        #endif
    }
}

/// Reads and writes text files. On the iPad they go through a file coordinator, so iCloud Drive
/// downloads a file that isn't on the device yet and never sees a half-written one.
nonisolated enum TextFileIO {
    static func read(_ url: URL) throws -> (text: String, format: TextFileFormat) {
        #if os(iOS)
        var result: Result<(text: String, format: TextFileFormat), Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try TextFileFormat.read(from: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
        #else
        try TextFileFormat.read(from: url)
        #endif
    }

    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result { try data.write(to: writeURL, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    /// Renames or moves a file or folder.
    static func move(_ source: URL, to target: URL) throws {
        #if os(iOS)
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forMoving,
                                                         writingItemAt: target, options: .forReplacing,
                                                         error: &coordinationError) { from, to in
            result = Result {
                try FileManager.default.moveItem(at: from, to: to)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        #else
        try FileManager.default.moveItem(at: source, to: target)
        #endif
    }

    #if os(iOS)
    /// Removes a file or folder: to the Recently Deleted folder in Files where iPadOS offers one,
    /// otherwise for good.
    static func delete(_ url: URL) {
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }
    #endif
}
