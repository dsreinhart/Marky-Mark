//
//  WikiLinkResolver.swift
//  Markwright
//
//  Turns a `[[Sheet name]]` into a file: in the library first, then beside the current document.
//

import Foundation

@MainActor
enum WikiLinkResolver {

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The file a wiki link points at, if it exists.
    static func resolve(_ target: String, near documentURL: URL?) -> URL? {
        let key = normalize(target)
        if let root = LibraryModel.shared.root {
            if let hit = root.allFiles.first(where: { normalize($0.name) == key }) { return hit.url }
        }
        if let folder = documentURL?.deletingLastPathComponent() {
            for ext in ["md", "markdown", "txt"] {
                let candidate = folder.appending(path: target + "." + ext)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
