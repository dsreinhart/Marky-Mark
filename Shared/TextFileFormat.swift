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

    /// How the characters are stored. Anything read as Windows-1252 is saved as UTF-8.
    enum Encoding: Equatable {
        case utf8, utf16LE, utf16BE, utf32LE, utf32BE

        var swiftEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16LE: return .utf16LittleEndian
            case .utf16BE: return .utf16BigEndian
            case .utf32LE: return .utf32LittleEndian
            case .utf32BE: return .utf32BigEndian
            }
        }

        var codeUnitSize: Int {
            switch self {
            case .utf8: return 1
            case .utf16LE, .utf16BE: return 2
            case .utf32LE, .utf32BE: return 4
            }
        }

        var bom: Data {
            switch self {
            case .utf8: return Data([0xEF, 0xBB, 0xBF])
            case .utf16LE: return Data([0xFF, 0xFE])
            case .utf16BE: return Data([0xFE, 0xFF])
            case .utf32LE: return Data([0xFF, 0xFE, 0x00, 0x00])
            case .utf32BE: return Data([0x00, 0x00, 0xFE, 0xFF])
            }
        }
    }

    var hasBOM = false
    var lineEnding: LineEnding = .lf
    var encoding: Encoding = .utf8

    static let bom = Encoding.utf8.bom

    /// The encoding a byte-order mark announces. UTF-32 goes first: its little-endian mark starts like UTF-16's.
    private static func encodingFromBOM(_ data: Data) -> Encoding? {
        [Encoding.utf32LE, .utf32BE, .utf8, .utf16LE, .utf16BE].first { data.starts(with: $0.bom) }
    }

    /// UTF-16 without a mark: Latin text in it has a zero in every other byte, which real
    /// UTF-8 text never does. Needed because those zeros are technically valid UTF-8.
    private static func guessUTF16(_ data: Data) -> Encoding? {
        guard data.count >= 4, data.count.isMultiple(of: 2) else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (index, byte) in data.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = data.count / 2
        if oddZeros * 10 >= half * 4, evenZeros == 0 { return .utf16LE }
        if evenZeros * 10 >= half * 4, oddZeros == 0 { return .utf16BE }
        return nil
    }

    /// Decodes file bytes into LF-normalized text, noting the BOM and line endings.
    /// Invalid UTF-8 falls back to Windows-1252 so old files still open; they are saved as UTF-8.
    static func decode(_ data: Data) -> (text: String, format: TextFileFormat) {
        var format = TextFileFormat()
        var bytes = data
        var raw: String? = nil
        if let marked = encodingFromBOM(data) {
            let body = Data(data.dropFirst(marked.bom.count))
            if marked == .utf8 {
                format.hasBOM = true
                bytes = body
            } else if body.count.isMultiple(of: marked.codeUnitSize), let text = String(data: body, encoding: marked.swiftEncoding) {
                format.hasBOM = true
                format.encoding = marked
                raw = text
            }
            // A damaged file claiming to be UTF-16 falls through and opens as ordinary text.
        } else if let guessed = guessUTF16(data), let text = String(data: data, encoding: guessed.swiftEncoding) {
            format.encoding = guessed
            raw = text
        }
        let decoded = raw
            ?? String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
        if decoded.contains("\r\n") {
            format.lineEnding = .crlf
        } else if decoded.contains("\r") {
            format.lineEnding = .cr
        }
        let text = format.lineEnding == .lf ? decoded : decoded.replacingOccurrences(of: format.lineEnding.rawValue, with: "\n")
        return (text, format)
    }

    static func read(from url: URL) throws -> (text: String, format: TextFileFormat) {
        decode(try Data(contentsOf: url))
    }

    /// The bytes to write for `text`, with the original BOM and line endings restored.
    func encode(_ text: String) -> Data {
        var out = hasBOM ? encoding.bom : Data()
        let body = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        out.append(body.data(using: encoding.swiftEncoding) ?? Data(body.utf8))
        return out
    }
}
