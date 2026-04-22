//
//  MarkdownParser.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import Foundation
import SwiftUI

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

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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

    // MARK: - Inline styling (bold, italic, inline code, strikethrough, links, images)

    static func styledText(_ text: String, theme: ThemeSettings = .shared) -> AttributedString {
        var result = AttributedString()
        let bodyFont = Font.system(size: theme.bodyFontSize)
        let pattern = /(!?\[[^\]]*\]\([^)]+\))|(~~)(.+?)(~~)|(`[^`]+`)|(\*\*\*|___)(.+?)(\*\*\*|___)|(\*\*|__)(.+?)(\*\*|__)|(\*|_)(.+?)(\*|_)/
        var remaining = text[...]

        while !remaining.isEmpty {
            if let match = remaining.firstMatch(of: pattern) {
                // Add plain text before the match
                let before = remaining[remaining.startIndex..<match.range.lowerBound]
                if !before.isEmpty {
                    result.append(AttributedString(String(before)))
                }

                if let linkOrImage = match.1 {
                    // Link or Image: [text](url) or ![alt](url)
                    let s = String(linkOrImage)
                    if s.hasPrefix("!") {
                        // Image: ![alt](url)
                        if let imgMatch = s.firstMatch(of: /!\[([^\]]*)\]\(([^)]+)\)/) {
                            let alt = String(imgMatch.1)
                            let url = String(imgMatch.2)
                            var attr = AttributedString(alt.isEmpty ? url : "\u{1F5BC} \(alt)")
                            attr.foregroundColor = theme.linkColor
                            attr.underlineStyle = .single
                            if let linkURL = URL(string: url) {
                                attr.link = linkURL
                            }
                            result.append(attr)
                        }
                    } else {
                        // Link: [text](url)
                        if let linkMatch = s.firstMatch(of: /\[([^\]]*)\]\(([^)]+)\)/) {
                            let label = String(linkMatch.1)
                            let url = String(linkMatch.2)
                            var attr = AttributedString(label)
                            attr.foregroundColor = theme.linkColor
                            attr.underlineStyle = .single
                            if let linkURL = URL(string: url) {
                                attr.link = linkURL
                            }
                            result.append(attr)
                        }
                    }
                } else if match.2 != nil, let inner = match.3 {
                    // Strikethrough ~~text~~
                    var attr = AttributedString(String(inner))
                    attr.strikethroughStyle = .single
                    attr.foregroundColor = theme.strikethroughColor
                    result.append(attr)
                } else if let code = match.5 {
                    // Inline code
                    var attr = AttributedString(String(code.dropFirst().dropLast()))
                    attr.font = .system(size: theme.bodyFontSize, design: .monospaced)
                    attr.backgroundColor = theme.inlineCodeBackground.opacity(0.5)
                    result.append(attr)
                } else if match.6 != nil, let inner = match.7 {
                    // Bold + Italic
                    var attr = AttributedString(String(inner))
                    attr.font = bodyFont.bold().italic()
                    result.append(attr)
                } else if match.9 != nil, let inner = match.10 {
                    // Bold
                    var attr = AttributedString(String(inner))
                    attr.font = bodyFont.bold()
                    result.append(attr)
                } else if match.12 != nil, let inner = match.13 {
                    // Italic
                    var attr = AttributedString(String(inner))
                    attr.font = bodyFont.italic()
                    result.append(attr)
                }

                remaining = remaining[match.range.upperBound...]
            } else {
                result.append(AttributedString(String(remaining)))
                break
            }
        }

        return result
    }
}
