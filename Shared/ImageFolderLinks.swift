//
//  ImageFolderLinks.swift
//  Markwright
//
//  The iPad saves pictures in a "<Document>-images" folder beside the document. These helpers find
//  which such folders a document's text links to and rewrite those links when pictures move, so a
//  renamed document can take its pictures with it.
//

import Foundation

enum ImageFolderLinks {
    /// The picture folder for a document with this name (without extension): "Field Notes" → "Field-Notes-images".
    static func folderName(forDocumentNamed name: String) -> String {
        let base = safeName(name)
        return (base.isEmpty ? "Untitled" : base) + "-images"
    }

    /// Letters, digits, "-" and "_"; everything else becomes "-".
    static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A path like "Name-images/file.jpg" that starts a link target: not part of a longer path or URL.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w./%-])([A-Za-z0-9_-]+-images)/([^\s)"'>\]]+)"#)

    private static func matches(in text: String) -> [(range: NSRange, folder: String, file: String)] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ($0.range, ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    /// "-images" folders beside the document that the text links into, in order of first use.
    static func linkedFolders(in text: String) -> [String] {
        var seen: [String] = []
        for match in matches(in: text) where !seen.contains(match.folder) { seen.append(match.folder) }
        return seen
    }

    /// The files inside `folder` that the text links to.
    static func linkedFiles(in text: String, folder: String) -> [String] {
        var seen: [String] = []
        for match in matches(in: text) where match.folder == folder && !seen.contains(match.file) { seen.append(match.file) }
        return seen
    }

    /// Whether the text links to anything inside `folder`.
    static func references(_ text: String, folder: String) -> Bool {
        matches(in: text).contains { $0.folder == folder }
    }

    /// Replaces links whose "folder/file" is a key of `moves` with its value.
    static func rewrite(_ text: String, moves: [String: String]) -> String {
        guard !moves.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches(in: text).reversed() {
            if let moved = moves[match.folder + "/" + match.file] {
                result.replaceCharacters(in: match.range, with: moved)
            }
        }
        return result as String
    }

    /// Whether a file name has the shape the iPad gives saved pictures: "<name>-YYYYMMDD-HHMMSS[-n].ext".
    static func isSavedPictureName(_ name: String) -> Bool {
        name.range(of: #"-\d{8}-\d{6}(-\d+)?\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    /// `name`, or "name-2.ext", "name-3.ext"… — the first that `isTaken` says is free.
    static func uniqueFileName(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var number = 2
        while true {
            let candidate = base + "-\(number)" + (ext.isEmpty ? "" : "." + ext)
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }
}
