//
//  TextStatistics.swift
//  Marky Mark
//
//  Word, character, sentence and paragraph counts, reading time, outline and
//  attachment lists for the dashboard. Comments and front matter are ignored.
//

import Foundation

struct OutlineEntry: Identifiable, Hashable {
    let id: Int
    let level: Int
    let text: String
}

struct AttachmentEntry: Identifiable, Hashable {
    enum Kind { case image, link }
    let id: Int
    let kind: Kind
    let label: String
    let target: String
}

@MainActor
struct TextStatistics {
    var words = 0
    var characters = 0
    var charactersNoSpaces = 0
    var sentences = 0
    var paragraphs = 0
    var headings = 0

    /// Reading time at roughly 220 words per minute.
    var readingMinutes: Int {
        words == 0 ? 0 : max(1, Int((Double(words) / 220).rounded(.up)))
    }

    static func compute(markdown: String) -> TextStatistics {
        var stats = TextStatistics()
        var parts: [String] = []
        for block in MarkdownParser.parse(markdown) {
            switch block {
            case .heading(_, let text):
                stats.headings += 1
                stats.paragraphs += 1
                parts.append(plain(text))
            case .paragraph(let text):
                stats.paragraphs += 1
                parts.append(plain(text))
            case .unorderedListItem(let text, _), .orderedListItem(_, let text, _), .taskListItem(_, let text, _):
                stats.paragraphs += 1
                parts.append(plain(text))
            case .blockquote(let text):
                stats.paragraphs += 1
                parts.append(text.components(separatedBy: "\n").map(plain).joined(separator: " "))
            case .codeBlock(_, let code):
                parts.append(code)
            case .table(let headers, let rows):
                parts.append((headers + rows.flatMap { $0 }).map(plain).joined(separator: " "))
            case .horizontalRule, .blank, .comment, .frontMatter:
                break
            }
        }
        let text = parts.joined(separator: "\n")
        stats.words = text.split { $0.isWhitespace || $0.isNewline }.count
        stats.characters = text.count
        stats.charactersNoSpaces = text.filter { !$0.isWhitespace }.count
        var sentences = 0
        (text as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (text as NSString).length),
                                               options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            if range.length > 0 { sentences += 1 }
        }
        stats.sentences = sentences
        return stats
    }

    /// The visible text of one inline markdown string.
    static func plain(_ inline: String) -> String {
        var out = ""
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .text(let s), .code(let s): out += s
                case .emphasis(let kids), .strong(let kids), .strike(let kids): walk(kids)
                case .link(let label, _): walk(label)
                case .image(let alt, _): out += alt
                }
            }
        }
        walk(InlineParser.parse(inline))
        return out
    }

    static func outline(markdown: String) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        for block in MarkdownParser.parse(markdown) {
            if case .heading(let level, let text) = block {
                entries.append(OutlineEntry(id: entries.count, level: level, text: plain(text)))
            }
        }
        return entries
    }

    static func attachments(markdown: String) -> [AttachmentEntry] {
        var entries: [AttachmentEntry] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .image(let alt, let source):
                    entries.append(AttachmentEntry(id: entries.count, kind: .image, label: alt.isEmpty ? source : alt, target: source))
                case .link(let label, let url):
                    entries.append(AttachmentEntry(id: entries.count, kind: .link, label: plainNodes(label), target: url))
                case .emphasis(let kids), .strong(let kids), .strike(let kids): walk(kids)
                case .text, .code: break
                }
            }
        }
        func scan(_ inline: String) { walk(InlineParser.parse(inline)) }
        for block in MarkdownParser.parse(markdown) {
            switch block {
            case .heading(_, let t), .paragraph(let t): scan(t)
            case .unorderedListItem(let t, _), .orderedListItem(_, let t, _), .taskListItem(_, let t, _): scan(t)
            case .blockquote(let t): t.components(separatedBy: "\n").forEach(scan)
            case .table(let headers, let rows): (headers + rows.flatMap { $0 }).forEach(scan)
            default: break
            }
        }
        return entries
    }

    private static func plainNodes(_ nodes: [InlineNode]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s), .code(let s): out += s
            case .emphasis(let kids), .strong(let kids), .strike(let kids), .link(let kids, _): out += plainNodes(kids)
            case .image(let alt, _): out += alt
            }
        }
        return out
    }
}
