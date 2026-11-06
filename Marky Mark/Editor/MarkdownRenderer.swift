//
//  MarkdownRenderer.swift
//  Marky Mark
//
//  Markdown → NSAttributedString for the rendered editor. The output carries the
//  semantic attributes from MarkdownModel.swift plus the visual attributes
//  produced by StyleEngine, so it can be dropped straight into the text view.
//

import AppKit

@MainActor
struct MarkdownRenderer {
    let engine: StyleEngine

    /// One paragraph of rendered output. `content` excludes the terminating newline.
    struct Paragraph {
        var content: NSMutableAttributedString
        var block: BlockInfo
        var paragraphStyle: NSParagraphStyle?
    }

    // MARK: - Public entry points

    /// Renders a whole document. With `trailingNewline`, the result ends with a newline
    /// so the document always has an empty, plain paragraph to type into at the end.
    func render(_ markdown: String, trailingNewline: Bool = true) -> NSMutableAttributedString {
        join(paragraphs(for: markdown), trailingNewline: trailingNewline)
    }

    func join(_ paragraphs: [Paragraph], trailingNewline: Bool) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            out.append(paragraph.content)
            if index < paragraphs.count - 1 || trailingNewline {
                out.append(newline(for: paragraph.block, paragraphStyle: paragraph.paragraphStyle))
            }
        }
        return out
    }

    /// A newline character carrying the attributes of the paragraph it terminates.
    func newline(for block: BlockInfo, paragraphStyle: NSParagraphStyle? = nil) -> NSAttributedString {
        NSAttributedString(string: "\n",
                           attributes: engine.attributes(block: block, inline: InlineStyle(), paragraphStyle: paragraphStyle))
    }

    /// Renders one line of inline markdown as content for an existing paragraph.
    func inlineContent(_ markdown: String,
                       block: BlockInfo,
                       paragraphStyle: NSParagraphStyle? = nil,
                       isHeaderCell: Bool = false) -> NSMutableAttributedString {
        inlineAttributed(InlineParser.parse(markdown), block: block, paragraphStyle: paragraphStyle,
                         base: InlineStyle(), isHeaderCell: isHeaderCell)
    }

    func paragraphs(for markdown: String) -> [Paragraph] {
        let blocks = MarkdownParser.parse(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        var result: [Paragraph] = []
        var counter = OrderedCounter()

        for block in blocks {
            switch block {
            case .blank:
                continue
            case .heading(let level, let text):
                let info = BlockInfo(.heading(level: level))
                _ = counter.next(for: info)
                result.append(paragraph(info, inlineText: text))
            case .paragraph(let text):
                _ = counter.next(for: .paragraph)
                result.append(paragraph(.paragraph, inlineText: text))
            case .unorderedListItem(let text, let indent):
                let info = BlockInfo(.bullet, indent: indent)
                _ = counter.next(for: info)
                result.append(listItem(info, number: 1, text: text))
            case .orderedListItem(_, let text, let indent):
                let info = BlockInfo(.ordered, indent: indent)
                let number = counter.next(for: info) ?? 1
                result.append(listItem(info, number: number, text: text))
            case .taskListItem(let checked, let text, let indent):
                let info = BlockInfo(.task(checked: checked), indent: indent)
                _ = counter.next(for: info)
                result.append(listItem(info, number: 1, text: text))
            case .codeBlock(let language, let code):
                let info = BlockInfo(.codeBlock(language: language))
                _ = counter.next(for: info)
                result.append(codeParagraph(info, code: code))
            case .blockquote(let text):
                let info = BlockInfo(.blockquote)
                _ = counter.next(for: info)
                result.append(quoteParagraph(info, text: text))
            case .horizontalRule:
                let info = BlockInfo(.horizontalRule)
                _ = counter.next(for: info)
                result.append(Paragraph(content: NSMutableAttributedString(), block: info, paragraphStyle: nil))
            case .table(let headers, let rows):
                _ = counter.next(for: BlockInfo(.tableCell))
                result.append(contentsOf: tableParagraphs(headers: headers, rows: rows))
            case .comment(let text):
                let info = BlockInfo(.comment)
                _ = counter.next(for: info)
                result.append(codeParagraph(info, code: text))
            case .frontMatter(let text):
                let info = BlockInfo(.frontMatter)
                _ = counter.next(for: info)
                result.append(codeParagraph(info, code: text))
            case .footnoteDefinition(let id, let text):
                let info = BlockInfo(.footnote(id: id))
                _ = counter.next(for: info)
                result.append(listItem(info, number: 1, text: text))
            }
        }
        return result
    }

    // MARK: - Block builders

    func paragraph(_ block: BlockInfo, inlineText: String) -> Paragraph {
        let content = inlineContent(inlineText, block: block)
        return Paragraph(content: content, block: block, paragraphStyle: nil)
    }

    func listItem(_ block: BlockInfo, number: Int, text: String) -> Paragraph {
        let content = NSMutableAttributedString(attributedString: engine.marker(for: block, number: number))
        content.append(inlineContent(text, block: block))
        return Paragraph(content: content, block: block, paragraphStyle: nil)
    }

    func codeParagraph(_ block: BlockInfo, code: String) -> Paragraph {
        let joined = code.replacingOccurrences(of: "\n", with: MarkdownSyntax.lineSeparatorString)
        let content = NSMutableAttributedString(string: joined,
                                                attributes: engine.attributes(block: block, inline: InlineStyle()))
        return Paragraph(content: content, block: block, paragraphStyle: nil)
    }

    func quoteParagraph(_ block: BlockInfo, text: String) -> Paragraph {
        let content = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            content.append(inlineContent(line, block: block))
            if index < lines.count - 1 {
                content.append(NSAttributedString(string: MarkdownSyntax.lineSeparatorString,
                                                  attributes: engine.attributes(block: block, inline: InlineStyle())))
            }
        }
        return Paragraph(content: content, block: block, paragraphStyle: nil)
    }

    /// Builds one paragraph per cell (header row first) backed by a shared NSTextTable.
    func tableParagraphs(headers: [String], rows: [[String]]) -> [Paragraph] {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0, 1)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.layoutAlgorithm = .automaticLayoutAlgorithm

        var result: [Paragraph] = []
        let allRows = [headers] + rows
        for (rowIndex, row) in allRows.enumerated() {
            for column in 0..<columns {
                let text = column < row.count ? row[column] : ""
                let cellBlock = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                                 startingColumn: column, columnSpan: 1)
                engine.configureTableBlock(cellBlock, isHeader: rowIndex == 0, columns: columns)
                let ps = engine.tableCellParagraphStyle(for: cellBlock, isLastRow: rowIndex == allRows.count - 1)
                let block = BlockInfo(.tableCell)
                let content = inlineContent(text, block: block, paragraphStyle: ps, isHeaderCell: rowIndex == 0)
                result.append(Paragraph(content: content, block: block, paragraphStyle: ps))
            }
        }
        return result
    }

    /// An empty table with placeholder headers, used by the toolbar.
    func emptyTableParagraphs(rows: Int, columns: Int) -> [Paragraph] {
        let headers = (1...max(columns, 1)).map { "Header \($0)" }
        let body = Array(repeating: Array(repeating: "", count: max(columns, 1)), count: max(rows, 1))
        return tableParagraphs(headers: headers, rows: body)
    }

    // MARK: - Inline

    private func inlineAttributed(_ nodes: [InlineNode],
                                  block: BlockInfo,
                                  paragraphStyle: NSParagraphStyle?,
                                  base: InlineStyle,
                                  isHeaderCell: Bool) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for node in nodes {
            switch node {
            case .text(let text):
                out.append(NSAttributedString(string: text, attributes: engine.attributes(
                    block: block, inline: base, paragraphStyle: paragraphStyle, isHeaderCell: isHeaderCell)))
            case .code(let text):
                var style = base
                style.code = true
                out.append(NSAttributedString(string: text, attributes: engine.attributes(
                    block: block, inline: style, paragraphStyle: paragraphStyle, isHeaderCell: isHeaderCell)))
            case .emphasis(let children):
                var style = base
                style.italic = true
                out.append(inlineAttributed(children, block: block, paragraphStyle: paragraphStyle,
                                            base: style, isHeaderCell: isHeaderCell))
            case .strong(let children):
                var style = base
                style.bold = true
                out.append(inlineAttributed(children, block: block, paragraphStyle: paragraphStyle,
                                            base: style, isHeaderCell: isHeaderCell))
            case .strike(let children):
                var style = base
                style.strike = true
                out.append(inlineAttributed(children, block: block, paragraphStyle: paragraphStyle,
                                            base: style, isHeaderCell: isHeaderCell))
            case .link(let label, let url):
                var style = base
                style.link = url
                out.append(inlineAttributed(label, block: block, paragraphStyle: paragraphStyle,
                                            base: style, isHeaderCell: isHeaderCell))
            case .image(let alt, let source):
                out.append(imageAttachment(alt: alt, source: source, block: block, paragraphStyle: paragraphStyle))
            case .highlight(let children):
                var style = base
                style.highlight = true
                out.append(inlineAttributed(children, block: block, paragraphStyle: paragraphStyle,
                                            base: style, isHeaderCell: isHeaderCell))
            case .tag(let name):
                var style = base
                style.tag = true
                out.append(NSAttributedString(string: "#" + name, attributes: engine.attributes(
                    block: block, inline: style, paragraphStyle: paragraphStyle, isHeaderCell: isHeaderCell)))
            case .wikiLink(let target, let label):
                var style = base
                style.wikiLink = target
                out.append(NSAttributedString(string: label ?? target, attributes: engine.attributes(
                    block: block, inline: style, paragraphStyle: paragraphStyle, isHeaderCell: isHeaderCell)))
            case .footnoteRef(let id):
                var style = base
                style.footnoteRef = id
                out.append(NSAttributedString(string: id, attributes: engine.attributes(
                    block: block, inline: style, paragraphStyle: paragraphStyle, isHeaderCell: isHeaderCell)))
            }
        }
        return out
    }

    func imageAttachment(alt: String, source: String,
                         block: BlockInfo, paragraphStyle: NSParagraphStyle?) -> NSAttributedString {
        let attachment = MarkdownImageAttachment(alt: alt, source: source, placeholderSize: engine.style.bodySize)
        let result = NSMutableAttributedString(attachment: attachment)
        result.setAttributes(engine.attachmentAttributes(block: block, attachment: attachment, isMarker: false,
                                                         paragraphStyle: paragraphStyle),
                             range: NSRange(location: 0, length: 1))
        return result
    }
}
