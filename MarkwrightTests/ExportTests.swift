//
//  ExportTests.swift
//  MarkwrightTests
//
//  Export styles, image embedding, and the Word and RTF conversion.
//

import AppKit
import Testing

@Suite("Export styles")
struct ExportStyleTests {
    @Test func cleanIsFirstAndTheFallback() {
        #expect(ExportStyle.allCases.first == .clean)
        #expect((ExportStyle(rawValue: "") ?? .clean) == .clean)
    }

    @Test func allEightAreOffered() {
        #expect(ExportStyle.allCases.map(\.label) == ["Clean", "Classic", "Modern", "Book", "Report", "Academic", "Technical", "Manuscript"])
    }

    /// People's saved choices are stored by these names.
    @Test func savedNamesKeepWorking() {
        for name in ["clean", "classic", "modern", "manuscript"] {
            #expect(ExportStyle(rawValue: name) != nil, "\(name)")
        }
    }

    @Test func eachIsDistinct() {
        #expect(Set(ExportStyle.allCases.map(\.css)).count == ExportStyle.allCases.count)
    }

    @Test(arguments: ExportStyle.allCases)
    func pageCarriesItsStyleAndHidesComments(style: ExportStyle) {
        let page = HTMLExporter.document(markdown: "---\ntags: [secret-tag]\n---\n\n# T\n\nBody\n\n<!-- private note -->", title: "T", style: style)
        #expect(page.contains(style.css))
        #expect(page.contains("Body"))
        #expect(!page.contains("private note"), "comments never reach an export")
        #expect(!page.contains("secret-tag"), "front matter never reaches an export")
    }

    /// Word and RTF go through Apple's HTML import, as the exporter does it.
    @Test(arguments: ExportStyle.allCases)
    func convertsToWordAndRTF(style: ExportStyle) throws {
        TestEnvironment.prepare()
        let html = HTMLExporter.document(markdown: "# T\n\nBody **bold**.[^1]\n\n[^1]: The note.", title: "T", style: style)
        let text = try NSAttributedString(data: Data(html.utf8),
                                          options: [.documentType: NSAttributedString.DocumentType.html,
                                                    .characterEncoding: String.Encoding.utf8.rawValue],
                                          documentAttributes: nil)
        #expect(text.string.contains("Body"))
        #expect(text.string.contains("The note."))
        let range = NSRange(location: 0, length: text.length)
        #expect(try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).count > 0)
        #expect(try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).count > 0)
    }

    /// The guide lists the styles by name, so a new one has to be added there too.
    @Test func guideNamesEveryStyle() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Markwright Help", withExtension: "md"))
        let guide = try String(contentsOf: url, encoding: .utf8)
        for style in ExportStyle.allCases {
            #expect(guide.contains("**\(style.label)**"), "\(style.label) is missing from the guide")
        }
    }
}

@Suite("Export images")
struct ExportImageTests {
    private func page(_ markdown: String) -> (String, TempFolder) {
        let folder = TempFolder()
        folder.write(bytes: Data("test".utf8), to: "pic.png")
        return (HTMLExporter.body(markdown: markdown, documentURL: folder.url.appending(path: "sheet.md")), folder)
    }

    @Test func imageBesideTheDocumentIsEmbedded() {
        let (html, folder) = page("![a](pic.png)")
        defer { _ = folder }
        #expect(html.contains("src=\"data:image/png;base64,dGVzdA==\""))
    }

    @Test func webImageStaysAnAddress() {
        let (html, folder) = page("![b](https://x/y.png)")
        defer { _ = folder }
        #expect(html.contains("src=\"https://x/y.png\""))
    }

    @Test func missingImageKeepsItsPath() {
        let (html, folder) = page("![c](missing.png)")
        defer { _ = folder }
        #expect(html.contains("src=\"missing.png\""))
    }

    @Test func withoutADocumentNothingIsEmbedded() {
        #expect(HTMLExporter.body(markdown: "![a](pic.png)").contains("src=\"pic.png\""))
    }
}
