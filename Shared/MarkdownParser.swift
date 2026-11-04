//
//  MarkdownParser.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import Foundation

// MARK: - Block types produced by the parser

enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case unorderedListItem(text: String, indent: Int)
    case orderedListItem(number: Int, text: String, indent: Int)
    case taskListItem(checked: Bool, text: String, indent: Int)
    case codeBlock(language: String, code: String)
    case blockquote(text: String)
    case horizontalRule
    case table(headers: [String], rows: [[String]])
    case comment(text: String)
    case frontMatter(text: String)
    case blank

    var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level)-\(text)"
        case .paragraph(let text): return "p-\(text.prefix(40))"
        case .unorderedListItem(let text, let indent): return "ul-\(indent)-\(text.prefix(40))"
        case .orderedListItem(let num, let text, let indent): return "ol-\(indent)-\(num)-\(text.prefix(40))"
        case .taskListItem(let checked, let text, let indent): return "task-\(checked)-\(indent)-\(text.prefix(40))"
        case .codeBlock(let lang, let code): return "code-\(lang)-\(code.prefix(40))"
        case .blockquote(let text): return "bq-\(text.prefix(40))"
        case .horizontalRule: return "hr-\(UUID().uuidString)"
        case .table(let headers, _): return "table-\(headers.joined(separator: "-"))"
        case .comment(let text): return "comment-\(text.prefix(40))"
        case .frontMatter(let text): return "frontmatter-\(text.prefix(40))"
        case .blank: return "blank-\(UUID().uuidString)"
        }
    }
}

// MARK: - Parser

struct MarkdownParser {

    static func parse(_ input: String) -> [MarkdownBlock] {
        let lines = input.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        // YAML front matter: a `---` fence on the very first line closed by another `---`.
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" {
            if let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                blocks.append(.frontMatter(text: lines[1..<close].joined(separator: "\n")))
                i = close + 1
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // HTML comment block (single or multi-line)
            if trimmed.hasPrefix("<!--") {
                var commentLines: [String] = []
                var finished = false
                while i < lines.count {
                    var piece = lines[i]
                    if commentLines.isEmpty, let open = piece.range(of: "<!--") {
                        piece = String(piece[open.upperBound...])
                    }
                    if let close = piece.range(of: "-->") {
                        piece = String(piece[..<close.lowerBound])
                        finished = true
                    }
                    let cleaned = piece.trimmingCharacters(in: .whitespaces)
                    if !(cleaned.isEmpty && (commentLines.isEmpty || finished)) || (!finished && !commentLines.isEmpty) {
                        commentLines.append(cleaned)
                    }
                    i += 1
                    if finished { break }
                }
                blocks.append(.comment(text: commentLines.joined(separator: "\n")))
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // Horizontal rule (---, ***, ___ with optional spaces)
            if trimmed.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil
                && !trimmed.contains(" ") || trimmed.range(of: #"^(- ){2,}-$"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^(\* ){2,}\*$"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^(_ ){2,}_$"#, options: .regularExpression) != nil {
                // Make sure it's not a list item (e.g. "- text")
                if trimmed.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil {
                    blocks.append(.horizontalRule)
                    i += 1
                    continue
                }
            }

            // Table — detect by pipe-delimited header + separator row
            if trimmed.contains("|") && i + 1 < lines.count {
                let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.range(of: #"^[|\s:-]+"#, options: .regularExpression) != nil
                    && nextTrimmed.contains("-") && nextTrimmed.contains("|") {
                    let headers = parseTableRow(line)
                    var rows: [[String]] = []
                    i += 2 // skip header and separator
                    while i < lines.count {
                        let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                        if rowLine.contains("|") && !rowLine.isEmpty {
                            rows.append(parseTableRow(lines[i]))
                            i += 1
                        } else {
                            break
                        }
                    }
                    blocks.append(.table(headers: headers, rows: rows))
                    continue
                }
            }

            // Heading
            if let headingMatch = line.prefixMatch(of: /^(#{1,6})\s+(.+)/) {
                let level = headingMatch.1.count
                let text = String(headingMatch.2)
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    if ql.hasPrefix(">") {
                        let content = ql.dropFirst().trimmingCharacters(in: .whitespaces)
                        quoteLines.append(content)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // Task list item - [ ] or - [x]
            if let taskMatch = line.prefixMatch(of: /^(\s*)[*\-+]\s+\[([ xX])\]\s+(.+)/) {
                let indent = taskMatch.1.count / 2
                let checked = taskMatch.2 != " "
                let text = String(taskMatch.3)
                blocks.append(.taskListItem(checked: checked, text: text, indent: indent))
                i += 1
                continue
            }

            // Unordered list item
            if let ulMatch = line.prefixMatch(of: /^(\s*)[*\-+]\s+(.+)/) {
                let indent = ulMatch.1.count / 2
                let text = String(ulMatch.2)
                blocks.append(.unorderedListItem(text: text, indent: indent))
                i += 1
                continue
            }

            // Ordered list item
            if let olMatch = line.prefixMatch(of: /^(\s*)(\d+)\.\s+(.+)/) {
                let indent = olMatch.1.count / 2
                let number = Int(olMatch.2) ?? 1
                let text = String(olMatch.3)
                blocks.append(.orderedListItem(number: number, text: text, indent: indent))
                i += 1
                continue
            }

            // Blank line
            if trimmed.isEmpty {
                blocks.append(.blank)
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-blank, non-special lines
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty
                    || nextTrimmed.hasPrefix("#")
                    || nextTrimmed.hasPrefix("<!--")
                    || nextTrimmed.hasPrefix("```")
                    || nextTrimmed.hasPrefix(">")
                    || nextTrimmed.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil
                    || nextTrimmed.prefixMatch(of: /^(\s*)[*\-+]\s+/) != nil
                    || nextTrimmed.prefixMatch(of: /^(\s*)\d+\.\s+/) != nil
                    || (nextTrimmed.contains("|") && i + 1 < lines.count
                        && lines[i + 1].trimmingCharacters(in: .whitespaces).contains("|")
                        && lines[i + 1].contains("-")) {
                    break
                }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(text: paragraphLines.joined(separator: " ")))
        }

        return blocks
    }

    // MARK: - Table row parsing

    private static func parseTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var content = trimmed
        if content.hasPrefix("|") { content = String(content.dropFirst()) }
        if content.hasSuffix("|") { content = String(content.dropLast()) }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
