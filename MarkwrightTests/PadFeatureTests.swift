//
//  PadFeatureTests.swift
//  MarkwrightTests
//
//  Shared pieces behind the iPad's table editor, Word export and library: the Markdown table
//  model, the .docx writer and its zip archive, and iCloud placeholders in a library folder.
//

import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Table editor model")
struct MarkdownTableTests {
    @Test func readsCellsAndAlignments() throws {
        let table = try #require(MarkdownTable.parse("""
        | Item | Qty | Note |
        | :--- | ---: | :---: |
        | Fuel | 80 | full tank |
        | Food | 120 |
        """))
        #expect(table.headers == ["Item", "Qty", "Note"])
        #expect(table.alignments == [.left, .right, .center])
        #expect(table.rows == [["Fuel", "80", "full tank"], ["Food", "120", ""]], "short rows are padded")
    }

    @Test func writesAlignedMarkdownThatReadsBackTheSame() throws {
        let table = MarkdownTable(headers: ["Item name", "Cost"], alignments: [.none, .right],
                                  rows: [["Fuel", "80"], ["Food", "120"]])
        #expect(table.markdown == """
        | Item name | Cost |
        | --------- | ---: |
        | Fuel      |   80 |
        | Food      |  120 |
        """)
        #expect(MarkdownTable.parse(table.markdown) == table)
        // The app's own parser sees the same table.
        guard case .table(let headers, let rows)? = MarkdownParser.parse(table.markdown).first else {
            Issue.record("not parsed as a table")
            return
        }
        #expect(headers == ["Item name", "Cost"])
        #expect(rows == [["Fuel", "80"], ["Food", "120"]])
    }

    @Test func pipesInCellsAreEscapedAndRestored() throws {
        let table = MarkdownTable(headers: ["A"], rows: [["x | y"]])
        #expect(table.markdown.contains("x \\| y"))
        #expect(MarkdownTable.parse(table.markdown)?.rows == [["x | y"]])
    }

    @Test func rowAndColumnEditing() {
        var table = MarkdownTable(headers: ["A", "B"], rows: [["1", "2"], ["3", "4"]])
        table.insertColumn(at: 1)
        #expect(table.headers == ["A", "", "B"])
        #expect(table.rows == [["1", "", "2"], ["3", "", "4"]])
        table.moveColumn(from: 2, by: -2)
        #expect(table.headers == ["B", "", "A"])
        table.removeColumn(at: 1)
        #expect(table.headers == ["B", "A"])
        #expect(table.alignments.count == 2)
        table.insertRow(at: 0)
        #expect(table.rows == [["", ""], ["2", "1"], ["4", "3"]])
        table.moveRow(from: 2, by: -1)
        #expect(table.rows == [["", ""], ["4", "3"], ["2", "1"]])
        table.removeRow(at: 0)
        #expect(table.rows == [["4", "3"], ["2", "1"]])
        // The last column can't go.
        var single = MarkdownTable(headers: ["Only"], rows: [["x"]])
        single.removeColumn(at: 0)
        #expect(single.headers == ["Only"])
    }

    @Test func notATable() {
        #expect(MarkdownTable.parse("Just a line | with a pipe") == nil)
        #expect(MarkdownTable.parse("") == nil)
    }
}

@Suite("Word export")
struct DocxWriterTests {
    private static let sample = """
    ---
    tags: demo
    ---
    # Trip notes

    Packing list with **bold**, *italic*, ~~gone~~, `code`, ==marked== and a [link](https://example.com).
    A footnote here.[^1]

    ## Days

    - First day
    - Second day
      - Nested
    1. One
    2. Two
    - [x] Booked
    - [ ] Packed

    > A quote line

    ```
    let x = 1
    ```

    ---

    | Item | Cost |
    | --- | ---: |
    | Fuel | 80 |

    ![Flower](flower.png)

    <!-- not exported -->

    [^1]: The footnote's text.
    """

    private func readBack(_ data: Data) throws -> NSAttributedString {
        let url = FileManager.default.temporaryDirectory.appending(path: "docx-\(UUID().uuidString).docx")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                      documentAttributes: nil)
    }

    private static func pngData(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func textAndStructureReadBackInAppKit() throws {
        let png = Self.pngData(width: 40, height: 20)
        let data = DocxWriter.make(markdown: Self.sample, title: "Trip notes") { source in
            source == "flower.png" ? png : nil
        }
        let text = try readBack(data)
        let string = text.string
        #expect(string.contains("Trip notes"))
        #expect(string.contains("Packing list with bold, italic, gone, code, marked and a link."))
        #expect(string.contains("First day"))
        #expect(string.contains("\u{2612} Booked"))
        #expect(string.contains("\u{2610} Packed"))
        #expect(string.contains("A quote line"))
        #expect(string.contains("let x = 1"))
        #expect(string.contains("Fuel"))
        #expect(!string.contains("not exported"), "comments stay out")
        #expect(!string.contains("tags: demo"), "front matter stays out")
        #expect(!string.contains("[^1]"))
        // Bold survives as a bold font.
        let bold = (string as NSString).range(of: "bold")
        let font = try #require(text.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func archiveHoldsTheExpectedParts() throws {
        let png = Self.pngData(width: 10, height: 10)
        let data = DocxWriter.make(markdown: Self.sample, title: "T") { _ in png }
        let names = ZipListing.names(in: data)
        #expect(names.first == "[Content_Types].xml")
        for part in ["_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml",
                     "word/footnotes.xml", "word/settings.xml", "word/_rels/document.xml.rels", "docProps/core.xml", "word/media/image1.png"] {
            #expect(names.contains(part), "missing \(part)")
        }
        let document = try #require(ZipListing.contents(of: "word/document.xml", in: data).flatMap { String(data: $0, encoding: .utf8) })
        #expect(document.contains("<w:pStyle w:val=\"Heading1\"/>"))
        #expect(document.contains("<w:footnoteReference w:id=\"1\"/>"))
        #expect(document.contains("<w:jc w:val=\"right\"/>"), "the right-aligned column")
        // AppKit's own Word reader ignores links and pictures, so they are checked in the XML.
        let relationships = try #require(ZipListing.contents(of: "word/_rels/document.xml.rels", in: data)
            .flatMap { String(data: $0, encoding: .utf8) })
        #expect(relationships.contains("Target=\"https://example.com\" TargetMode=\"External\""))
        #expect(relationships.contains("Target=\"media/image1.png\""))
        #expect(document.contains("<w:hyperlink r:id="))
        #expect(document.contains("<a:blip r:embed="))
        #expect(document.contains("descr=\"Flower\""))
        let footnotes = try #require(ZipListing.contents(of: "word/footnotes.xml", in: data).flatMap { String(data: $0, encoding: .utf8) })
        #expect(footnotes.contains("The footnote&apos;s text") || footnotes.contains("The footnote's text"))
    }

    @Test func missingPictureLeavesItsAltText() throws {
        let data = DocxWriter.make(markdown: "Before ![A flower](missing.png) after", title: "T") { _ in nil }
        #expect(try readBack(data).string.contains("Before A flower after"))
    }

    @Test func imageSourcesAreFoundEverywhere() {
        let markdown = "![a](one.png)\n\n- ![b](two.png)\n\n| x |\n| - |\n| ![c](three.png) |\n\n![a](one.png)"
        #expect(DocxWriter.imageSources(in: markdown) == ["one.png", "two.png", "three.png"])
    }

    @Test func localImageDataReadsFilesAndDataURLs() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "docx-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = Self.pngData(width: 4, height: 4)
        try png.write(to: folder.appending(path: "My pic.png"))
        #expect(DocxWriter.localImageData("My%20pic.png", documentFolder: folder) == png)
        #expect(DocxWriter.localImageData("data:image/png;base64," + png.base64EncodedString(), documentFolder: nil) == png)
        #expect(DocxWriter.localImageData("https://example.com/x.png", documentFolder: folder) == nil)
    }

    @Test func documentEmbedsAPictureBesideTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "docx-doc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "Trip-images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = Self.pngData(width: 30, height: 20)
        try png.write(to: folder.appending(path: "Trip-images/shot.png"))
        let data = await DocxWriter.document(markdown: "# Trip\n\n![Shot](Trip-images/shot.png)\n\n![Gone](missing.png)",
                                             title: "Trip", documentFolder: folder)
        let names = ZipListing.names(in: data)
        #expect(names.contains("word/media/image1.png"))
        #expect(!names.contains("word/media/image2.png"), "a missing picture adds nothing")
        #expect(ZipListing.contents(of: "word/media/image1.png", in: data) == png, "PNG goes in unchanged")
        #expect(try readBack(data).string.contains("Gone"), "and leaves its alt text")
    }

    @Test func crcMatchesTheStandardCheckValue() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite("Library iCloud placeholders")
struct LibraryPlaceholderTests {
    @Test func placeholderNamesMapToTheirFiles() {
        let folder = URL(fileURLWithPath: "/tmp/lib")
        #expect(LibraryModel.iCloudPlaceholderTarget(folder.appending(path: ".Trip notes.md.icloud"))?.lastPathComponent == "Trip notes.md")
        #expect(LibraryModel.iCloudPlaceholderTarget(folder.appending(path: "Trip notes.md")) == nil)
        #expect(LibraryModel.iCloudPlaceholderTarget(folder.appending(path: ".DS_Store")) == nil)
    }
}

/// Reads the stored (uncompressed) entries of a zip archive, enough to check the writer's output.
enum ZipListing {
    private static func u16(_ data: Data, _ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
    private static func u32(_ data: Data, _ offset: Int) -> Int { u16(data, offset) | u16(data, offset + 2) << 16 }

    static func entries(in data: Data) -> [(name: String, contents: Data)] {
        var result: [(String, Data)] = []
        var offset = 0
        let bytes = Data(data)
        while offset + 30 <= bytes.count, u32(bytes, offset) == 0x0403_4B50 {
            let size = u32(bytes, offset + 18)
            let nameLength = u16(bytes, offset + 26)
            let extraLength = u16(bytes, offset + 28)
            let nameStart = offset + 30
            let name = String(data: bytes[nameStart..<nameStart + nameLength], encoding: .utf8) ?? ""
            let dataStart = nameStart + nameLength + extraLength
            result.append((name, bytes[dataStart..<dataStart + size]))
            offset = dataStart + size
        }
        return result
    }

    static func names(in data: Data) -> [String] { entries(in: data).map(\.name) }

    static func contents(of name: String, in data: Data) -> Data? {
        entries(in: data).first { $0.name == name }?.contents
    }
}

@Suite("Saving pictures beside a document")
struct PictureStoreTests {
    private static func png(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func smallPNGIsKeptAndNamedWithADate() throws {
        let data = Self.png(width: 40, height: 30)
        let prepared = try #require(PictureStore.prepare(data: data, suggestedName: "My Logo.png", type: .png))
        #expect(prepared.data == data)
        #expect(prepared.ext == "png")
        #expect(prepared.alt == "My Logo")
        #expect(ImageFolderLinks.isSavedPictureName(prepared.fileName), "\(prepared.fileName)")
        #expect(prepared.fileName.hasPrefix("My-Logo-"))
    }

    @Test func largePictureIsScaledDownToJPEG() throws {
        let prepared = try #require(PictureStore.prepare(data: Self.png(width: 3200, height: 1600), suggestedName: "wide.png", type: .png))
        #expect(prepared.ext == "jpg")
        let size = try #require(Self.pixelSize(prepared.data))
        #expect(size.0 == 1600 && size.1 == 800)
    }

    @Test func notAPicture() {
        #expect(PictureStore.prepare(data: Data("hello".utf8), suggestedName: "x.png", type: .png) == nil)
    }

    @Test func storesBesideTheDocumentInItsPictureFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appending(path: "Trip notes.md")
        try Data("# Trip".utf8).write(to: document)
        let prepared = try #require(PictureStore.prepare(data: Self.png(width: 20, height: 20), suggestedName: "shot.png", type: .png))
        let first = try PictureStore.storeBeside(prepared, documentURL: document, text: "# Trip")
        let second = try PictureStore.storeBeside(prepared, documentURL: document, text: "# Trip")
        #expect(first.source.hasPrefix("Trip-notes-images/shot-"))
        #expect(second.source != first.source, "a second copy gets its own name")
        #expect(!first.embedded)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: first.source).path))
        // A document already using another picture folder keeps using it.
        #expect(PictureStore.pictureFolder(for: document, text: "![a](Old-images/a.png)") == "Old-images")
    }

    @Test func picturesAlreadyInTheDocumentFolderAreLinkedWhereTheyAre() {
        let document = URL(fileURLWithPath: "/tmp/docs/Notes.md")
        #expect(PictureStore.pathInsideDocumentFolder(URL(fileURLWithPath: "/tmp/docs/Notes-images/a.png"), documentURL: document) == "Notes-images/a.png")
        #expect(PictureStore.pathInsideDocumentFolder(URL(fileURLWithPath: "/tmp/elsewhere/a.png"), documentURL: document) == nil)
        #expect(PictureStore.pathInsideDocumentFolder(URL(fileURLWithPath: "/tmp/docs/a.png"), documentURL: nil) == nil)
    }

    @Test func embeddedPictureIsADataURL() throws {
        let prepared = try #require(PictureStore.prepare(data: Self.png(width: 8, height: 8), suggestedName: nil, type: .png))
        let stored = PictureStore.embed(prepared)
        #expect(stored.embedded)
        #expect(stored.source.hasPrefix("data:image/png;base64,"))
        #expect(stored.alt == "Image")
    }
}
