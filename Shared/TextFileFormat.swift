//
//  TextFileFormat.swift
//  Markwright
//
//  Remembers how a file was encoded on disk (byte-order mark, line endings) so a
//  save writes it back the way it came, and version control sees only real changes.
//  In memory the text always uses "\n".
//

import Foundation

nonisolated struct TextFileFormat: Equatable {
    enum LineEnding: String {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    var hasBOM = false
    var lineEnding: LineEnding = .lf

    static let bom = Data([0xEF, 0xBB, 0xBF])

    /// Decodes file bytes into LF-normalized text, noting the BOM and line endings.
    /// Invalid UTF-8 falls back to Windows-1252 so old files still open; they are saved as UTF-8.
    static func decode(_ data: Data) -> (text: String, format: TextFileFormat) {
        var format = TextFileFormat()
        var bytes = data
        if bytes.starts(with: bom) {
            format.hasBOM = true
            bytes = bytes.dropFirst(bom.count)
        }
        let raw = String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
        if raw.contains("\r\n") {
            format.lineEnding = .crlf
        } else if raw.contains("\r") {
            format.lineEnding = .cr
        }
        let text = format.lineEnding == .lf ? raw : raw.replacingOccurrences(of: format.lineEnding.rawValue, with: "\n")
        return (text, format)
    }

    static func read(from url: URL) throws -> (text: String, format: TextFileFormat) {
        decode(try Data(contentsOf: url))
    }

    /// The bytes to write for `text`, with the original BOM and line endings restored.
    func encode(_ text: String) -> Data {
        var out = hasBOM ? Self.bom : Data()
        let body = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        out.append(Data(body.utf8))
        return out
    }
}
