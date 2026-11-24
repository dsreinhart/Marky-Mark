//
//  PadImageStore.swift
//  Markwright iPad
//
//  Saving a picked picture is shared with the Mac (PictureStore); this keeps a renamed
//  document's pictures with it.
//

import Foundation
import UniformTypeIdentifiers

@MainActor
enum PadImageStore {

    typealias Stored = PictureStore.Stored
    typealias Prepared = PictureStore.Prepared

    static func prepare(data: Data, suggestedName: String?, type: UTType?) -> Prepared? {
        PictureStore.prepare(data: data, suggestedName: suggestedName, type: type)
    }

    static func storeBeside(_ prepared: Prepared, documentURL: URL, text: String) throws -> Stored {
        try PictureStore.storeBeside(prepared, documentURL: documentURL, text: text)
    }

    static func embed(_ prepared: Prepared) -> Stored {
        PictureStore.embed(prepared)
    }

    // MARK: Keeping pictures with a renamed document

    /// When the document links into picture folders named for something else (it was renamed, here
    /// or in Files), moves those pictures into "<Document>-images" and returns the text with its
    /// links updated. Returns nil when there is nothing to do or it isn't safe: a folder that
    /// another document beside it also links to, or one we can't check, is left alone.
    static func adoptPictures(text: String, documentURL: URL) -> String? {
        let own = ImageFolderLinks.folderName(forDocumentNamed: documentURL.deletingPathExtension().lastPathComponent)
        let foreign = ImageFolderLinks.linkedFolders(in: text).filter { $0 != own }
        guard !foreign.isEmpty else { return nil }
        let base = documentURL.deletingLastPathComponent()
        // The app's own folder needs no grant; elsewhere, without one the listing below fails and nothing moves.
        PadFolderAccess.begin(base)
        let fm = FileManager.default
        let target = base.appending(path: own, directoryHint: .isDirectory)
        var moves: [String: String] = [:]
        for folderName in foreign {
            let source = base.appending(path: folderName, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                // Already moved (the app stopped before the new links were saved): point the links at the moved files.
                for file in ImageFolderLinks.linkedFiles(in: text, folder: folderName)
                where fm.fileExists(atPath: target.appending(path: file).path) {
                    moves[folderName + "/" + file] = own + "/" + file
                }
                continue
            }
            if let other = otherDocumentLinking(to: folderName, besides: documentURL) {
                // Also reached when the folder can't be listed (no access): nothing is moved.
                PadDiagnostics.log("pictures in \(folderName) left in place: \(other) links to them too")
                continue
            }
            guard let files = try? fm.contentsOfDirectory(atPath: source.path) else { continue }
            // Only folders the iPad made: every picture has its dated name ("photo-20261120-084924.jpg").
            guard files.filter({ !$0.hasPrefix(".") }).allSatisfy(ImageFolderLinks.isSavedPictureName) else {
                PadDiagnostics.log("pictures in \(folderName) left in place: it holds files Markwright didn't name")
                continue
            }
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                PadDiagnostics.log("couldn't create \(own): \(error)")
                return moves.isEmpty ? nil : ImageFolderLinks.rewrite(text, moves: moves)
            }
            for file in files where !file.hasPrefix(".") {
                let name = ImageFolderLinks.uniqueFileName(file) { fm.fileExists(atPath: target.appending(path: $0).path) }
                if move(source.appending(path: file), to: target.appending(path: name)) {
                    moves[folderName + "/" + file] = own + "/" + name
                }
            }
            if ((try? fm.contentsOfDirectory(atPath: source.path)) ?? ["?"]).allSatisfy({ $0.hasPrefix(".") }) {
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: source, options: .forDeleting, error: &error) { url in
                    try? fm.removeItem(at: url)
                }
            }
            PadDiagnostics.log("moved \(moves.count) picture(s) from \(folderName) to \(own)")
        }
        guard !moves.isEmpty else { return nil }
        return ImageFolderLinks.rewrite(text, moves: moves)
    }

    /// Name of another document beside `documentURL` whose text links into `folderName`, or
    /// "an unreadable file" when one can't be read (so the folder is treated as shared).
    private static func otherDocumentLinking(to folderName: String, besides documentURL: URL) -> String? {
        let base = documentURL.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return "an unreadable folder" }
        let textTypes: Set = ["md", "markdown", "mdown", "mkd", "txt", "text"]
        for name in names where name != documentURL.lastPathComponent {
            // An iCloud file that isn't downloaded yet can show as ".Name.md.icloud".
            var real = name
            if real.hasPrefix("."), real.hasSuffix(".icloud") { real = String(real.dropFirst().dropLast(7)) }
            guard textTypes.contains((real as NSString).pathExtension.lowercased()) else { continue }
            if real != name { return real }   // can't read it without downloading; assume shared
            var contents: String?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: base.appending(path: name), options: [], error: &error) { url in
                contents = try? String(contentsOf: url, encoding: .utf8)
            }
            guard let contents else { return name }
            if ImageFolderLinks.references(contents, folder: folderName) { return name }
        }
        return nil
    }

    private static func move(_ source: URL, to destination: URL) -> Bool {
        var moved = false
        var error: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
                moved = true
            } catch {
                PadDiagnostics.log("couldn't move \(from.lastPathComponent): \(error)")
            }
        }
        return moved && error == nil
    }
}
