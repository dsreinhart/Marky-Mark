//
//  MarkdownSerializer.swift
//  Markwright
//
//  NSAttributedString (from the rendered editor) → Markdown. Only the semantic
//  attributes are consulted; fonts and colors are ignored.
//

import AppKit

@MainActor
enum MarkdownSerializer {

    // MARK: - Document

    static func markdown(from text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var emitter = Emitter()
        var counter = OrderedCounter()
        var table: TableAccumulator? = nil

        var location = 0
        while location < ns.length {
            let paragraphRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if paragraphRange.length == 0 { break }
            location = NSMaxRange(paragraphRange)

            var content = paragraphRange
            if ns.character(at: NSMaxRange(paragraphRange) - 1) == MarkdownSyntax.newlineUTF16 {
                content.length -= 1
            }

            let attrs = text.attributes(at: paragraphRange.location, effectiveRange: nil)
            let block = attrs[.mmBlock] as? BlockInfo ?? .paragraph
            let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle

            // Table cells are grouped by their NSTextTable and flushed together.
            if let cellBlock = paragraphStyle?.textBlocks.first as? NSTextTableBlock {
                let cellText = inlineMarkdown(text, range: content)
                    .replacingOccurrences(of: MarkdownSyntax.lineSeparatorString, with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\u{00A6}")
                if table == nil || table!.table !== cellBlock.table {
                    table?.flush(into: &emitter)
                    table = TableAccumulator(table: cellBlock.table)
                }
                table!.add(row: cellBlock.startingRow, column: cellBlock.startingColumn, text: cellText)
                _ = counter.next(for: BlockInfo(.tableCell))
                continue
            }
            table?.flush(into: &emitter)
            table = nil

            let number = counter.next(for: block)
            let indent = String(repeating: "  ", count: block.indent)

            switch block.kind {
            case .paragraph, .tableCell:
                let inline = inlineMarkdown(text, range: content)
                let lines = inline.components(separatedBy: MarkdownSyntax.lineSeparatorString)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue   // empty paragraphs contribute nothing
                }
                emitter.emit(lines.map(escapeLineStart))
            case .heading(let level):
                let inline = singleLine(inlineMarkdown(text, range: content))
                if inline.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                emitter.emit([String(repeating: "#", count: min(max(level, 1), 6)) + " " + inline])
            case .bullet:
                let inline = singleLine(inlineMarkdown(text, range: content))
                if inline.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                emitter.emit([indent + "- " + escapeTaskLookalike(inline)], list: block)
            case .ordered:
                let inline = singleLine(inlineMarkdown(text, range: content))
                if inline.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                emitter.emit([indent + "\(number ?? 1). " + inline], list: block)
            case .task(let checked):
                let inline = singleLine(inlineMarkdown(text, range: content))
                if inline.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                emitter.emit([indent + (checked ? "- [x] " : "- [ ] ") + inline], list: block)
            case .blockquote:
                let inline = inlineMarkdown(text, range: content)
                let lines = inline.components(separatedBy: MarkdownSyntax.lineSeparatorString)
                emitter.emit(lines.map { "> " + $0 })
            case .codeBlock(let language):
                let raw = rawText(text, range: content)
                let lines = raw.components(separatedBy: MarkdownSyntax.lineSeparatorString)
                emitter.emit(["```" + language] + lines + ["```"])
            case .horizontalRule:
                emitter.emit(["---"])
            case .comment:
                let raw = rawText(text, range: content)
                let lines = raw.components(separatedBy: MarkdownSyntax.lineSeparatorString)
                if lines.count == 1 {
                    emitter.emit(["<!-- " + lines[0] + " -->"])
                } else {
                    emitter.emit(["<!--"] + lines + ["-->"])
                }
            case .frontMatter:
                let raw = rawText(text, range: content)
                emitter.emit(["---"] + raw.components(separatedBy: MarkdownSyntax.lineSeparatorString) + ["---"])
            case .footnote(let id):
                let inline = singleLine(inlineMarkdown(text, range: content))
                emitter.emit(["[^\(id)]: " + inline], list: block)
            }
        }
        table?.flush(into: &emitter)
        return emitter.lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private struct Emitter {
        var lines: [String] = []
        private var lastList: BlockInfo? = nil
        private var listKindByIndent: [Int: BlockKind] = [:]
        private var hasContent = false

        /// Consecutive list items stay adjacent, including nested items and the return to a
        /// parent list. A list of another kind at the same level gets a blank line before it.
        mutating func emit(_ newLines: [String], list: BlockInfo? = nil) {
            var continuesList = false
            if let list, let lastList {
                if list.indent > lastList.indent {
                    continuesList = true
                } else if let sibling = listKindByIndent[list.indent] {
                    continuesList = sibling.isSameFamily(as: list.kind)
                }
            }
            if hasContent && !continuesList {
                lines.append("")
            }
            lines.append(contentsOf: newLines)
            if let list {
                for key in listKindByIndent.keys where key > list.indent { listKindByIndent[key] = nil }
                listKindByIndent[list.indent] = list.kind
            } else {
                listKindByIndent.removeAll()
            }
            lastList = list
            hasContent = true
        }
    }

    private struct TableAccumulator {
        let table: NSTextTable
        private var cells: [Int: [Int: String]] = [:]

        init(table: NSTextTable) { self.table = table }

        mutating func add(row: Int, column: Int, text: String) {
            var rowCells = cells[row] ?? [:]
            let existing = rowCells[column] ?? ""
            rowCells[column] = existing.isEmpty ? text : (text.isEmpty ? existing : existing + " " + text)
            cells[row] = rowCells
        }

        func flush(into emitter: inout Emitter) {
            let columns = max(table.numberOfColumns, 1)
            let rowIndices = cells.keys.sorted()
            guard let firstRow = rowIndices.first else { return }
            func line(for row: Int) -> String {
                let values = (0..<columns).map { cells[row]?[$0] ?? "" }
                return "| " + values.joined(separator: " | ") + " |"
            }
            var lines = [line(for: firstRow)]
            lines.append("|" + Array(repeating: " --- |", count: columns).joined())
            for row in rowIndices.dropFirst() {
                lines.append(line(for: row))
            }
            emitter.emit(lines)
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: MarkdownSyntax.lineSeparatorString, with: " ")
    }

    /// Text of a range with markers and attachments removed and no inline processing.
    private static func rawText(_ text: NSAttributedString, range: NSRange) -> String {
        var out = ""
        let ns = text.string as NSString
        text.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
            if attrs[.mmMarker] != nil || attrs[.attachment] != nil { return }
            out += ns.substring(with: runRange)
        }
        return out
    }

    // MARK: - Inline

    private enum Segment {
        case text(String, InlineStyle)
        case image(alt: String, source: String)
    }

    private enum Wrapper: Equatable {
        case link(String)
        case strike
        case highlight
        case bold
        case italic

        var open: String {
            switch self {
            case .link: return "["
            case .strike: return "~~"
            case .highlight: return "=="
            case .bold: return "**"
            case .italic: return "*"
            }
        }

        var close: String {
            switch self {
            case .link(let url): return "](\(url))"
            case .strike: return "~~"
            case .highlight: return "=="
            case .bold: return "**"
            case .italic: return "*"
            }
        }

        static func wanted(by style: InlineStyle) -> [Wrapper] {
            var list: [Wrapper] = []
            if let link = style.link, !link.isEmpty { list.append(.link(link)) }
            if style.strike { list.append(.strike) }
            if style.highlight { list.append(.highlight) }
            if style.bold { list.append(.bold) }
            if style.italic { list.append(.italic) }
            return list
        }
    }

    /// Serializes the inline content of a range (markers are skipped).
    static func inlineMarkdown(_ text: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let ns = text.string as NSString
        var segments: [Segment] = []
        text.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
            if attrs[.mmMarker] != nil { return }
            if let attachment = attrs[.attachment] {
                if let image = attachment as? MarkdownImageAttachment {
                    segments.append(.image(alt: image.alt, source: image.source))
                }
                return
            }
            segments.append(.text(ns.substring(with: runRange), InlineStyle(attributes: attrs)))
        }

        // Merge adjacent runs with identical style.
        var merged: [Segment] = []
        for segment in segments {
            if case .text(let string, let style) = segment,
               case .text(let previous, let previousStyle)? = merged.last,
               style == previousStyle {
                merged[merged.count - 1] = .text(previous + string, style)
            } else {
                merged.append(segment)
            }
        }

        var out = ""
        var open: [Wrapper] = []

        func transition(to wanted: [Wrapper]) {
            var common = 0
            while common < open.count, common < wanted.count, open[common] == wanted[common] {
                common += 1
            }
            for wrapper in open[common...].reversed() { out += wrapper.close }
            for wrapper in wanted[common...] { out += wrapper.open }
            open = wanted
        }

        /// Wrappers for a style, keeping the currently open ones in order so as few as possible are closed.
        func orderedWanted(_ style: InlineStyle) -> [Wrapper] {
            let desired = Wrapper.wanted(by: style)
            var ordered = open.filter { desired.contains($0) }
            for wrapper in desired where !ordered.contains(wrapper) { ordered.append(wrapper) }
            return ordered
        }

        func wanted(of segment: Segment?) -> [Wrapper] {
            guard case .text(_, let style)? = segment else { return [] }
            return Wrapper.wanted(by: style)
        }

        // Whitespace at a style boundary is emitted outside the wrappers that change there,
        // so the delimiters stay flanking and the markup parses back to the same styles.
        for (index, segment) in merged.enumerated() {
            let nextWanted = wanted(of: index + 1 < merged.count ? merged[index + 1] : nil)
            switch segment {
            case .image(let alt, let source):
                transition(to: [])
                out += "![\(alt.replacingOccurrences(of: "]", with: "\\]"))](\(source))"
            case .text(let string, let style):
                // Wiki links and footnote references are atomic tokens.
                if let target = style.wikiLink {
                    var outer = style
                    outer.wikiLink = nil
                    transition(to: orderedWanted(outer))
                    let label = string.trimmingCharacters(in: .whitespaces)
                    out += (label.isEmpty || label == target) ? "[[\(target)]]" : "[[\(target)|\(label)]]"
                    continue
                }
                if let id = style.footnoteRef {
                    var outer = style
                    outer.footnoteRef = nil
                    transition(to: orderedWanted(outer))
                    out += "[^\(id)]"
                    continue
                }
                let chars = Array(string)
                var coreStart = 0
                while coreStart < chars.count, chars[coreStart].isWhitespace { coreStart += 1 }
                var coreEnd = chars.count
                while coreEnd > coreStart, chars[coreEnd - 1].isWhitespace { coreEnd -= 1 }
                let lead = coreStart < chars.count ? String(chars[0..<coreStart]) : ""
                let core = String(chars[coreStart..<coreEnd])
                let trail = coreStart < chars.count ? String(chars[coreEnd...]) : string

                let wantedHere = orderedWanted(style)
                if !lead.isEmpty {
                    transition(to: open.filter { wantedHere.contains($0) })
                    out += lead
                }
                if !core.isEmpty {
                    transition(to: wantedHere)
                    out += style.code ? codeSpan(core) : escape(core)
                }
                if !trail.isEmpty {
                    transition(to: open.filter { nextWanted.contains($0) })
                    out += trail
                }
            }
        }
        transition(to: [])
        return out
    }

    private static func codeSpan(_ text: String) -> String {
        if text.contains("`") {
            return "`` " + text + " ``"
        }
        return "`" + text + "`"
    }

    /// Escapes characters that would otherwise be read as inline markup.
    static func escape(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        for (index, c) in chars.enumerated() {
            let prev: Character? = index > 0 ? chars[index - 1] : nil
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            switch c {
            case "\\":
                out += "\\\\"
            case "`":
                out += "\\`"
            case "*", "_":
                let (canOpen, canClose) = InlineParser.flanking(char: c, prev: prev, next: next)
                out += (canOpen || canClose) ? "\\\(c)" : String(c)
            case "~":
                out += (prev == "~" || next == "~") ? "\\~" : "~"
            case "=":
                out += (prev == "=" || next == "=") ? "\\=" : "="
            case "[":
                if next == "[" || next == "^" {
                    out += "\\["
                } else {
                    let rest = String(chars[(index + 1)...])
                    out += rest.contains("](") ? "\\[" : "["
                }
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Prevents a plain paragraph line from being parsed as a block construct.
    private static let lineStartPattern = try! NSRegularExpression(
        pattern: #"^(#{1,6}(\s|$)|[-+*](\s|$)|\d+\.(\s|$)|>|```|\||[-*_]{3,}\s*$)"#)

    static func escapeLineStart(_ line: String) -> String {
        let ns = line as NSString
        if lineStartPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
            return "\\" + line
        }
        return line
    }

    private static func escapeTaskLookalike(_ content: String) -> String {
        let pattern = #"^\[[ xX]\]"#
        if content.range(of: pattern, options: .regularExpression) != nil {
            return "\\" + content
        }
        return content
    }
}
