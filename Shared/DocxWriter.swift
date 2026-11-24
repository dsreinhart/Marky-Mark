//
//  DocxWriter.swift
//  Markwright
//
//  Word (.docx) export written by hand, for the iPad, which has no Word writer of its own (the Mac
//  uses AppKit's). The document is built from the parsed Markdown: headings, paragraphs, lists,
//  task lists, quotes, code, rules, tables, links, footnotes and pictures, with Word's own heading
//  and list styles, and packed into a zip archive.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DocxWriter {

    /// Builds the .docx file. `imageData` returns the bytes of a picture's source (a path beside the
    /// document, a `data:` URL or a web address fetched beforehand), or nil to leave its alt text.
    static func make(markdown: String, title: String, imageData: @escaping (String) -> Data?) -> Data {
        var builder = Builder(imageData: imageData)
        builder.build(markdown: markdown)
        var archive = ZipArchive()
        archive.add("[Content_Types].xml", builder.contentTypes)
        archive.add("_rels/.rels", Self.packageRelationships)
        archive.add("docProps/core.xml", Self.coreProperties(title: title))
        archive.add("word/document.xml", builder.documentXML)
        archive.add("word/styles.xml", Self.styles)
        archive.add("word/numbering.xml", builder.numberingXML)
        archive.add("word/footnotes.xml", builder.footnotesXML)
        archive.add("word/settings.xml", Self.settings)
        archive.add("word/_rels/document.xml.rels", builder.documentRelationships)
        for image in builder.images {
            archive.add("word/media/\(image.name)", image.data)
        }
        return archive.archive
    }

    /// The .docx for a document, with its pictures: files beside it (`documentFolder`), embedded
    /// `data:` pictures, and pictures on the web, fetched first (10 seconds each at most; a picture
    /// that can't be fetched is left as its alt text).
    static func document(markdown: String, title: String, documentFolder: URL?) async -> Data {
        var remote: [String: Data] = [:]
        for source in imageSources(in: markdown) {
            let lower = source.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            if let (data, response) = try? await URLSession.shared.data(for: request),
               ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 {
                remote[source] = data
            }
        }
        return make(markdown: markdown, title: title) { source in
            remote[source] ?? localImageData(source, documentFolder: documentFolder)
        }
    }

    /// Every picture source in the document, in order, without repeats.
    static func imageSources(in markdown: String) -> [String] {
        var sources: [String] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .image(_, let source, _): if !sources.contains(source) { sources.append(source) }
                case .emphasis(let children), .strong(let children), .strike(let children), .highlight(let children):
                    walk(children)
                case .link(let label, _): walk(label)
                default: break
                }
            }
        }
        for block in MarkdownParser.parse(markdown) {
            switch block {
            case .heading(_, let text), .paragraph(let text), .unorderedListItem(let text, _),
                 .orderedListItem(_, let text, _), .taskListItem(_, let text, _), .blockquote(let text),
                 .footnoteDefinition(_, let text):
                walk(InlineParser.parse(text))
            case .table(let headers, let rows):
                for cell in headers + rows.flatMap({ $0 }) { walk(InlineParser.parse(cell)) }
            default:
                break
            }
        }
        return sources
    }

    /// The bytes of a picture referenced from a document: a `data:` URL, or a file beside it.
    /// Web addresses return nil here; the exporter fetches those first.
    static func localImageData(_ source: String, documentFolder: URL?) -> Data? {
        let lower = source.lowercased()
        if lower.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ",") else { return nil }
            let header = source[..<comma]
            let payload = String(source[source.index(after: comma)...])
            return header.contains(";base64") ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                : payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return nil }
        let url: URL
        if lower.hasPrefix("file://"), let fileURL = URL(string: source) {
            url = fileURL
        } else if let documentFolder {
            url = URL(fileURLWithPath: source.removingPercentEncoding ?? source, relativeTo: documentFolder).standardizedFileURL
        } else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    // MARK: - Building the document

    private struct Image {
        let name: String
        let relationship: String
        let data: Data
        let widthEMU: Int
        let heightEMU: Int
    }

    private struct RunStyle {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var highlight = false
        var hyperlink = false
        var superscript = false

        var xml: String {
            var props = ""
            if hyperlink { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if code { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Courier New\"/>" }
            if bold { props += "<w:b/>" }
            if italic { props += "<w:i/>" }
            if strike { props += "<w:strike/>" }
            if code { props += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EEEEEE\"/>" }
            if highlight { props += "<w:highlight w:val=\"yellow\"/>" }
            if superscript { props += "<w:vertAlign w:val=\"superscript\"/>" }
            return props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
        }
    }

    private struct Builder {
        let imageData: (String) -> Data?
        private(set) var body = ""
        private(set) var images: [Image] = []
        private var links: [(id: String, url: String)] = []
        private var footnoteIDs: [String: Int] = [:]
        private var footnoteBodies: [Int: String] = [:]
        /// Numbering instances: 1 is bullets; each numbered list after that gets its own, so it starts at 1.
        private var orderedInstances: [Int] = []
        private var currentOrdered: Int? = nil
        private var nextRelationship = 10
        private var nextDrawing = 1

        init(imageData: @escaping (String) -> Data?) {
            self.imageData = imageData
        }

        mutating func build(markdown: String) {
            let lines = markdown.components(separatedBy: "\n")
            for (block, range) in MarkdownParser.parseWithLines(markdown) {
                switch block {
                case .orderedListItem: break
                default: currentOrdered = nil
                }
                switch block {
                case .heading(let level, let text):
                    paragraph(style: "Heading\(min(max(level, 1), 6))", content: inline(text))
                case .paragraph(let text):
                    paragraph(style: nil, content: inline(text))
                case .unorderedListItem(let text, let indent):
                    paragraph(style: "ListParagraph", numbering: (1, min(indent, 8)), content: inline(text))
                case .orderedListItem(_, let text, let indent):
                    let instance: Int
                    if let current = currentOrdered {
                        instance = current
                    } else {
                        instance = 2 + orderedInstances.count
                        orderedInstances.append(instance)
                        currentOrdered = instance
                    }
                    paragraph(style: "ListParagraph", numbering: (instance, min(indent, 8)), content: inline(text))
                case .taskListItem(let checked, let text, let indent):
                    let box = run(checked ? "\u{2612} " : "\u{2610} ", style: RunStyle())
                    paragraph(style: "ListParagraph", indentTwips: 360 * (indent + 1), content: box + inline(text))
                case .codeBlock(_, let code):
                    for line in code.components(separatedBy: "\n") {
                        paragraph(style: "Code", content: run(line, style: RunStyle()))
                    }
                case .blockquote(let text):
                    for line in text.components(separatedBy: "\n") {
                        paragraph(style: "Quote", content: inline(line))
                    }
                case .horizontalRule:
                    body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr></w:pPr></w:p>"
                case .table(let headers, let rows):
                    let source = lines[range.clamped(to: 0..<lines.count)].joined(separator: "\n")
                    let alignments = MarkdownTable.parse(source)?.alignments ?? []
                    table(headers: headers, rows: rows, alignments: alignments)
                case .footnoteDefinition(let id, let text):
                    let number = footnoteNumber(id)
                    footnoteBodies[number] = inline(text)
                case .blank, .comment, .frontMatter:
                    break
                }
            }
            if body.isEmpty { body = "<w:p/>" }
        }

        // MARK: Paragraphs

        private mutating func paragraph(style: String?, numbering: (instance: Int, level: Int)? = nil,
                                        indentTwips: Int? = nil, content: String) {
            var props = ""
            if let style { props += "<w:pStyle w:val=\"\(style)\"/>" }
            if let numbering {
                props += "<w:numPr><w:ilvl w:val=\"\(numbering.level)\"/><w:numId w:val=\"\(numbering.instance)\"/></w:numPr>"
            }
            if let indentTwips { props += "<w:ind w:left=\"\(indentTwips)\"/>" }
            body += "<w:p>" + (props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>") + content + "</w:p>"
        }

        private mutating func table(headers: [String], rows: [[String]], alignments: [MarkdownTable.Alignment]) {
            let columns = max(headers.count, rows.map(\.count).max() ?? 0, 1)
            let width = 9000 / columns
            var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(width * columns)\" w:type=\"dxa\"/>"
            xml += "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
                "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>"
            }.joined() + "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblLook w:val=\"04A0\" w:firstRow=\"1\"/></w:tblPr>"
            xml += "<w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
            for (rowIndex, row) in ([headers] + rows).enumerated() {
                let isHeader = rowIndex == 0
                xml += "<w:tr>" + (isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                for column in 0..<columns {
                    let text = column < row.count ? row[column] : ""
                    var cellProps = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                    if isHeader { cellProps += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>" }
                    var paragraphProps = "<w:spacing w:before=\"40\" w:after=\"40\"/>"
                    switch column < alignments.count ? alignments[column] : .none {
                    case .center: paragraphProps += "<w:jc w:val=\"center\"/>"
                    case .right: paragraphProps += "<w:jc w:val=\"right\"/>"
                    default: break
                    }
                    let content = inline(text, bold: isHeader)
                    xml += "<w:tc><w:tcPr>\(cellProps)</w:tcPr><w:p><w:pPr>\(paragraphProps)</w:pPr>\(content)</w:p></w:tc>"
                }
                xml += "</w:tr>"
            }
            xml += "</w:tbl>"
            body += xml + "<w:p/>"
        }

        // MARK: Inline content

        private mutating func inline(_ markdown: String, bold: Bool = false) -> String {
            var style = RunStyle()
            style.bold = bold
            return render(InlineParser.parse(markdown.replacingOccurrences(of: "\n", with: " ")), style: style)
        }

        private mutating func render(_ nodes: [InlineNode], style: RunStyle) -> String {
            var out = ""
            for node in nodes {
                switch node {
                case .text(let text):
                    out += run(text, style: style)
                case .code(let text):
                    var code = style
                    code.code = true
                    out += run(text, style: code)
                case .emphasis(let children):
                    var italic = style
                    italic.italic = true
                    out += render(children, style: italic)
                case .strong(let children):
                    var bold = style
                    bold.bold = true
                    out += render(children, style: bold)
                case .strike(let children):
                    var struck = style
                    struck.strike = true
                    out += render(children, style: struck)
                case .highlight(let children):
                    var marked = style
                    marked.highlight = true
                    out += render(children, style: marked)
                case .link(let label, let url):
                    var linked = style
                    linked.hyperlink = true
                    let id = linkRelationship(url)
                    out += "<w:hyperlink r:id=\"\(id)\" w:history=\"1\">" + render(label, style: linked) + "</w:hyperlink>"
                case .image(let alt, let source, let width):
                    out += picture(source: source, alt: alt, width: width) ?? run(alt.isEmpty ? "[image]" : alt, style: style)
                case .tag(let name):
                    out += run("#" + name, style: style)
                case .wikiLink(let target, let label):
                    out += run(label ?? target, style: style)
                case .footnoteRef(let id):
                    let number = footnoteNumber(id)
                    out += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(number)\"/></w:r>"
                }
            }
            return out
        }

        private func run(_ text: String, style: RunStyle) -> String {
            guard !text.isEmpty else { return "" }
            return "<w:r>\(style.xml)<w:t xml:space=\"preserve\">\(DocxWriter.escape(text))</w:t></w:r>"
        }

        private mutating func linkRelationship(_ url: String) -> String {
            if let existing = links.first(where: { $0.url == url }) { return existing.id }
            let id = "rId\(nextRelationship)"
            nextRelationship += 1
            links.append((id, url))
            return id
        }

        private mutating func footnoteNumber(_ id: String) -> Int {
            if let number = footnoteIDs[id] { return number }
            let number = footnoteIDs.count + 1   // -1 and 0 are the separator lines
            footnoteIDs[id] = number
            return number
        }

        // MARK: Pictures

        private mutating func picture(source: String, alt: String, width setWidth: PictureWidth?) -> String? {
            guard let raw = imageData(source), let prepared = DocxWriter.wordImage(raw) else { return nil }
            let index = images.count + 1
            let relationship = "rId\(nextRelationship)"
            nextRelationship += 1
            // Sized as on screen, in CSS pixels (96 per inch): the width set in the Markdown, or the
            // picture's own size (a 144 dpi Retina screenshot is half its pixel count). At most
            // 6 inches wide, the text width of a Letter or A4 page; percentages are of that width.
            let emuPerPixel = 9525.0
            let textWidth = 6.0 * 96
            let scale = 72 / prepared.dpi
            let naturalWidth = Double(prepared.pixelWidth) * scale
            let naturalHeight = Double(prepared.pixelHeight) * scale
            let cssWidth = setWidth?.cssPixels(fullWidth: textWidth) ?? min(naturalWidth, textWidth)
            let width = cssWidth * emuPerPixel
            let height = naturalHeight * cssWidth / naturalWidth * emuPerPixel
            let image = Image(name: "image\(index).\(prepared.fileExtension)", relationship: relationship, data: prepared.data,
                              widthEMU: Int(width), heightEMU: Int(height))
            images.append(image)
            let drawing = nextDrawing
            nextDrawing += 1
            let description = DocxWriter.escape(alt)
            return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
            <wp:extent cx="\(image.widthEMU)" cy="\(image.heightEMU)"/>\
            <wp:docPr id="\(drawing)" name="Picture \(drawing)" descr="\(description)"/>\
            <wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>\
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:nvPicPr><pic:cNvPr id="\(drawing)" name="\(image.name)" descr="\(description)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(image.widthEMU)" cy="\(image.heightEMU)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
        }

        // MARK: Parts

        var documentXML: Data {
            Data(("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
            <w:body>
            """ + body + """
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>\
            </w:sectPr></w:body></w:document>
            """).utf8)
        }

        var footnotesXML: Data {
            var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <w:footnote w:type="separator" w:id="-1"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:separator/></w:r></w:p></w:footnote>\
            <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
            """
            for number in footnoteIDs.values.sorted() {
                xml += "<w:footnote w:id=\"\(number)\"><w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>"
                xml += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r>"
                xml += "<w:r><w:t xml:space=\"preserve\"> </w:t></w:r>" + (footnoteBodies[number] ?? "") + "</w:p></w:footnote>"
            }
            xml += "</w:footnotes>"
            return Data(xml.utf8)
        }

        var numberingXML: Data {
            func levels(ordered: Bool) -> String {
                (0..<9).map { level in
                    let indent = 720 * (level + 1)
                    if ordered {
                        let formats = ["decimal", "lowerLetter", "lowerRoman"]
                        return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(formats[level % 3])\"/>"
                            + "<w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/>"
                            + "<w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                    }
                    let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
                    return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/>"
                        + "<w:lvlText w:val=\"\(bullets[level % 3])\"/><w:lvlJc w:val=\"left\"/>"
                        + "<w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                }.joined()
            }
            var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            """
            xml += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(ordered: false))</w:abstractNum>"
            xml += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(ordered: true))</w:abstractNum>"
            xml += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
            for instance in orderedInstances {
                xml += "<w:num w:numId=\"\(instance)\"><w:abstractNumId w:val=\"1\"/>"
                xml += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
            }
            xml += "</w:numbering>"
            return Data(xml.utf8)
        }

        var documentRelationships: Data {
            let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(type)/styles" Target="styles.xml"/>\
            <Relationship Id="rId2" Type="\(type)/numbering" Target="numbering.xml"/>\
            <Relationship Id="rId3" Type="\(type)/footnotes" Target="footnotes.xml"/>\
            <Relationship Id="rId4" Type="\(type)/settings" Target="settings.xml"/>
            """
            for link in links {
                xml += "<Relationship Id=\"\(link.id)\" Type=\"\(type)/hyperlink\" Target=\"\(DocxWriter.escape(link.url))\" TargetMode=\"External\"/>"
            }
            for image in images {
                xml += "<Relationship Id=\"\(image.relationship)\" Type=\"\(type)/image\" Target=\"media/\(image.name)\"/>"
            }
            xml += "</Relationships>"
            return Data(xml.utf8)
        }

        var contentTypes: Data {
            let main = "application/vnd.openxmlformats-officedocument.wordprocessingml"
            let xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Default Extension="jpeg" ContentType="image/jpeg"/>\
            <Default Extension="gif" ContentType="image/gif"/>\
            <Override PartName="/word/document.xml" ContentType="\(main).document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="\(main).styles+xml"/>\
            <Override PartName="/word/numbering.xml" ContentType="\(main).numbering+xml"/>\
            <Override PartName="/word/footnotes.xml" ContentType="\(main).footnotes+xml"/>\
            <Override PartName="/word/settings.xml" ContentType="\(main).settings+xml"/>\
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
            </Types>
            """
            return Data(xml.utf8)
        }
    }

    // MARK: - Fixed parts

    private static let packageRelationships = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """.utf8)

    private static let settings = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/>\
    <w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr>\
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>\
    </w:settings>
    """.utf8)

    private static func coreProperties(title: String) -> Data {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escape(title))</dc:title>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified>\
        </cp:coreProperties>
        """.utf8)
    }

    private static let styles: Data = {
        func heading(_ level: Int, size: Int) -> String {
            """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/>\
            <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:spacing w:before="\(level <= 2 ? 360 : 240)" w:after="120"/><w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
            <w:rPr><w:b/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr></w:style>
            """
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:eastAsia="Helvetica Neue" w:cs="Arial"/>\
        <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>\
        <w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>\
        \(heading(1, size: 40))\(heading(2, size: 32))\(heading(3, size: 28))\(heading(4, size: 24))\(heading(5, size: 22))\(heading(6, size: 22))\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="60"/><w:contextualSpacing/></w:pPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="A6A6A6"/></w:pBdr><w:ind w:left="360"/></w:pPr>\
        <w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Courier New"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>\
        <w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/>\
        <w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>\
        <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/>\
        <w:tblPr><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        </w:styles>
        """
        return Data(xml.utf8)
    }()

    // MARK: - Helpers

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // XML 1.0 has no place for other control characters.
                if scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private struct PreparedImage {
        let data: Data
        let fileExtension: String
        let pixelWidth: Int
        let pixelHeight: Int
        /// Dots per inch from the file (72 when it has none), so it's drawn at its on-screen size.
        let dpi: Double
    }

    /// A picture Word can show: PNG, JPEG and GIF as they are, anything else (HEIC, WebP, TIFF)
    /// turned into PNG. Nil when the bytes aren't a picture.
    private static func wordImage(_ data: Data) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // Pictures turned on their side by EXIF orientation are drawn upright by Word only when re-encoded.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let fileDPI = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpi = fileDPI >= 36 && fileDPI <= 1200 ? fileDPI : 72
        let type = CGImageSourceGetType(source) as String?
        let keep: [String: String] = [UTType.png.identifier: "png", UTType.jpeg.identifier: "jpeg", UTType.gif.identifier: "gif"]
        if let type, let ext = keep[type], orientation == 1 {
            return PreparedImage(data: data, fileExtension: ext, pixelWidth: width, pixelHeight: height, dpi: dpi)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        width = image.width
        height = image.height
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedImage(data: output as Data, fileExtension: "png", pixelWidth: width, pixelHeight: height, dpi: dpi)
    }
}

// MARK: - Zip

/// A zip archive with the files stored uncompressed, which Word and other readers accept.
nonisolated struct ZipArchive {
    private(set) var data = Data()
    private var central = Data()
    private var count = 0

    mutating func add(_ name: String, _ contents: Data) {
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(contents)
        let offset = UInt32(data.count)
        // Local file header.
        data.append(le32: 0x0403_4B50)
        data.append(le16: 20)          // version needed
        data.append(le16: 0x0800)      // UTF-8 names
        data.append(le16: 0)           // stored
        data.append(le16: 0)           // time
        data.append(le16: 0x21)        // date: 1980-01-01
        data.append(le32: crc)
        data.append(le32: UInt32(contents.count))
        data.append(le32: UInt32(contents.count))
        data.append(le16: UInt16(nameBytes.count))
        data.append(le16: 0)
        data.append(nameBytes)
        data.append(contents)
        // Its central directory entry.
        central.append(le32: 0x0201_4B50)
        central.append(le16: 20)
        central.append(le16: 20)
        central.append(le16: 0x0800)
        central.append(le16: 0)
        central.append(le16: 0)
        central.append(le16: 0x21)
        central.append(le32: crc)
        central.append(le32: UInt32(contents.count))
        central.append(le32: UInt32(contents.count))
        central.append(le16: UInt16(nameBytes.count))
        central.append(le16: 0)        // extra
        central.append(le16: 0)        // comment
        central.append(le16: 0)        // disk
        central.append(le16: 0)        // internal attributes
        central.append(le32: 0)        // external attributes
        central.append(le32: offset)
        central.append(nameBytes)
        count += 1
    }

    /// The finished archive.
    var archive: Data {
        var out = data
        let directoryOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(count))
        out.append(le16: UInt16(count))
        out.append(le32: UInt32(central.count))
        out.append(le32: directoryOffset)
        out.append(le16: 0)
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private nonisolated extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
