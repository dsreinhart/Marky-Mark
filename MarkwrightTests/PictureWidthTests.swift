//
//  PictureWidthTests.swift
//  MarkwrightTests
//
//  `{width=…}` after a picture: parsing, the formatted view's size, HTML and Word.
//

import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Picture width")
struct PictureWidthTests {

    @Test(arguments: [
        ("50%", 50.0, PictureWidth.Unit.percent), ("300px", 300, .px), ("300", 300, .px), ("2in", 2, .inch),
        ("1.5CM", 1.5, .cm), ("40mm", 40, .mm), ("144pt", 144, .pt), (".5in", 0.5, .inch),
    ])
    func parsesValues(text: String, value: Double, unit: PictureWidth.Unit) throws {
        let width = try #require(PictureWidth(text))
        #expect(width.value == value)
        #expect(width.unit == unit)
        #expect(width.text == text)
    }

    @Test(arguments: ["", "abc", "0", "-5%", "150%", "2 feet", "1.2.3in", "50%%"])
    func rejectsNonsense(text: String) {
        #expect(PictureWidth(text) == nil)
    }

    @Test func convertsToCSSPixels() throws {
        #expect(try #require(PictureWidth("50%")).cssPixels(fullWidth: 600) == 300)
        #expect(try #require(PictureWidth("2in")).cssPixels(fullWidth: 600) == 192)
        #expect(try #require(PictureWidth("72pt")).cssPixels(fullWidth: 600) == 96)
        #expect(try #require(PictureWidth("2.54cm")).cssPixels(fullWidth: 600) == 96)
        #expect(try #require(PictureWidth("9in")).cssPixels(fullWidth: 600) == 600, "never wider than the column")
        #expect(try #require(PictureWidth("300")).css == "300px")
        #expect(try #require(PictureWidth("2IN")).css == "2in")
    }

    @Test func parserReadsTheWidth() {
        #expect(InlineParser.parse("![Chart](chart.png){width=50%}") ==
                [.image(alt: "Chart", source: "chart.png", width: PictureWidth("50%"))])
        #expect(InlineParser.parse("![a](a.png) {width=50%}") ==
                [.image(alt: "a", source: "a.png"), .text(" {width=50%}")], "only right after the picture")
        #expect(InlineParser.parse("[link](x.html){width=50%}") ==
                [.link(label: [.text("link")], url: "x.html"), .text("{width=50%}")], "links take no width")
    }

    @Test func formattedViewSize() {
        let natural = CGSize(width: 800, height: 400)
        let plain = MarkdownImageAttachment(alt: "", source: "a.png", placeholderSize: 14)
        #expect(plain.displaySize(natural: natural, maxWidth: 600) == CGSize(width: 600, height: 300))
        #expect(plain.displaySize(natural: CGSize(width: 200, height: 100), maxWidth: 600) == CGSize(width: 200, height: 100))
        let half = MarkdownImageAttachment(alt: "", source: "a.png", width: PictureWidth("50%"), placeholderSize: 14)
        #expect(half.displaySize(natural: natural, maxWidth: 600) == CGSize(width: 300, height: 150))
        let wide = MarkdownImageAttachment(alt: "", source: "a.png", width: PictureWidth("400px"), placeholderSize: 14)
        #expect(wide.displaySize(natural: CGSize(width: 200, height: 100), maxWidth: 600) == CGSize(width: 400, height: 200),
                "a set width may enlarge a small picture")
    }

    @MainActor @Test func htmlCarriesTheWidth() {
        #expect(HTMLExporter.body(markdown: "![a](pic.png){width=50%}").contains("<img src=\"pic.png\" alt=\"a\" style=\"width: 50%\">"))
        #expect(HTMLExporter.body(markdown: "![a](pic.png)").contains("<img src=\"pic.png\" alt=\"a\">"))
    }

    // MARK: Word

    /// A PNG of `width` × `height` pixels marked with `dpi` dots per inch.
    private static func png(width: Int, height: Int, dpi: Double) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!,
                                   [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// The `cx`/`cy` of the first picture in the Word document, in EMU (914,400 per inch).
    private static func extent(markdown: String, png: Data) throws -> (Int, Int) {
        let data = DocxWriter.make(markdown: markdown, title: "T") { _ in png }
        let document = try #require(ZipListing.contents(of: "word/document.xml", in: data).flatMap { String(data: $0, encoding: .utf8) })
        let match = try #require(document.firstMatch(of: /<wp:extent cx="(\d+)" cy="(\d+)"\/>/))
        return (Int(match.1)!, Int(match.2)!)
    }

    @Test func wordUsesThePicturesResolution() throws {
        // 400 px at 144 dpi is 200 CSS pixels on screen: 200 × 9525 EMU.
        let retina = try Self.extent(markdown: "![a](a.png)", png: Self.png(width: 400, height: 200, dpi: 144))
        #expect(retina.0 == 1_905_000 && retina.1 == 952_500)
        let plain = try Self.extent(markdown: "![a](a.png)", png: Self.png(width: 400, height: 200, dpi: 72))
        #expect(plain.0 == 3_810_000 && plain.1 == 1_905_000)
        let huge = try Self.extent(markdown: "![a](a.png)", png: Self.png(width: 4000, height: 1000, dpi: 72))
        #expect(huge.0 == 6 * 914_400 && huge.1 == 6 * 914_400 / 4, "at most 6 inches wide")
    }

    @Test func wordUsesTheMarkdownWidth() throws {
        let png = Self.png(width: 400, height: 200, dpi: 144)
        let half = try Self.extent(markdown: "![a](a.png){width=50%}", png: png)
        #expect(half.0 == 3 * 914_400 && half.1 == 3 * 914_400 / 2, "half of the 6 inch text width")
        let inches = try Self.extent(markdown: "![a](a.png){width=2in}", png: png)
        #expect(inches.0 == 2 * 914_400 && inches.1 == 914_400)
    }
}

@Suite("Picture resize handles")
struct ImageResizeTests {
    private let frame = CGRect(x: 100, y: 50, width: 200, height: 100)

    @Test func handlesSitOnTheCorners() {
        #expect(ImageResize.corner(at: CGPoint(x: 101, y: 49), of: frame, reach: 7) == .topLeft)
        #expect(ImageResize.corner(at: CGPoint(x: 305, y: 155), of: frame, reach: 7) == .bottomRight)
        #expect(ImageResize.corner(at: CGPoint(x: 300, y: 50), of: frame, reach: 7) == .topRight)
        #expect(ImageResize.corner(at: CGPoint(x: 200, y: 100), of: frame, reach: 7) == nil, "the middle isn't a handle")
        #expect(ImageResize.corner(at: CGPoint(x: 310, y: 150), of: frame, reach: 7) == nil, "too far")
    }

    @Test func dragGivesAWholePercentOfTheColumn() {
        // 200 of a 600 column is 33%; 60 more to the right is 260 = 43%.
        #expect(ImageResize.percent(startWidth: 200, dx: 60, corner: .bottomRight, columnWidth: 600) == 43)
        // Left-hand corners grow when dragged left.
        #expect(ImageResize.percent(startWidth: 200, dx: -60, corner: .topLeft, columnWidth: 600) == 43)
        #expect(ImageResize.percent(startWidth: 200, dx: 60, corner: .bottomLeft, columnWidth: 600) == 23)
        #expect(ImageResize.percent(startWidth: 200, dx: 900, corner: .bottomRight, columnWidth: 600) == 100)
        #expect(ImageResize.percent(startWidth: 200, dx: -900, corner: .bottomRight, columnWidth: 600) == ImageResize.minimumPercent)
    }

    @Test func sizeKeepsTheShape() {
        #expect(ImageResize.size(natural: CGSize(width: 800, height: 400), percent: 50, columnWidth: 600) == CGSize(width: 300, height: 150))
    }

    @MainActor @Test func settingTheWidthWritesItAndUndoes() {
        let editor = FormattedEditor()
        editor.load("Before ![Chart](chart.png) after.")
        let index = (editor.textView.string as NSString).range(of: "\u{FFFC}").location
        #expect(index != NSNotFound)
        editor.coordinator.setImageWidth(percent: 40, at: index)
        #expect(editor.text == "Before ![Chart](chart.png){width=40%} after.")
        #expect(editor.textView.selectedRange() == NSRange(location: index, length: 1), "the picture stays selected")
        editor.coordinator.setImageWidth(percent: 75, at: index)
        #expect(editor.text == "Before ![Chart](chart.png){width=75%} after.")
        // Both changes fall in one event here, so one undo takes back both.
        editor.textView.undoManager?.undo()
        #expect(editor.text == "Before ![Chart](chart.png) after.")
    }
}

@Suite("Picture handles in the formatted view")
@MainActor
struct ImageHandleOverlayTests {
    private static let png: String = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return "data:image/png;base64," + rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }()

    /// An editor whose one picture has loaded.
    private func editorWithPicture() async throws -> (FormattedEditor, Int) {
        let editor = FormattedEditor()
        editor.load("Intro\n\n![Pic](\(Self.png))\n\nAfter")
        let index = (editor.textView.string as NSString).range(of: "\u{FFFC}").location
        let attachment = try #require(editor.textView.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? MarkdownImageAttachment)
        for _ in 0..<100 where !attachment.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        #expect(attachment.isLoaded)
        return (editor, index)
    }

    @Test func selectingAPictureShowsHandlesOverIt() async throws {
        let (editor, index) = try await editorWithPicture()
        #expect(editor.coordinator.imageHandles?.isHidden ?? true, "nothing selected yet")
        editor.textView.setSelectedRange(NSRange(location: index, length: 1))
        let overlay = try #require(editor.coordinator.imageHandles)
        #expect(!overlay.isHidden)
        #expect(overlay.superview === editor.textView)
        #expect(overlay.pictureFrame.size == CGSize(width: 400, height: 200))
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(overlay.isHidden)
    }

    @Test func draggingACornerWritesThePercent() async throws {
        let (editor, index) = try await editorWithPicture()
        editor.textView.setSelectedRange(NSRange(location: index, length: 1))
        let overlay = try #require(editor.coordinator.imageHandles)
        overlay.onDrag?(.bottomRight, -100, false)
        #expect(overlay.label != nil, "the width shows while dragging")
        overlay.onDrag?(.bottomRight, -100, true)
        let text = editor.text
        #expect(text.contains("){width="))
        #expect(editor.textView.selectedRange() == NSRange(location: index, length: 1))
        #expect(editor.coordinator.imageHandles?.label == nil)
    }

    @Test func clickingAPictureSelectsIt() async throws {
        let (editor, index) = try await editorWithPicture()
        editor.textView.setSelectedRange(NSRange(location: index, length: 1))
        let overlay = try #require(editor.coordinator.imageHandles)
        let picture = overlay.convert(overlay.pictureFrame, to: editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.coordinator.handleMouseDown(NSEvent.mouseEvent(
            with: .leftMouseDown, location: editor.textView.convert(CGPoint(x: picture.midX, y: picture.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!))
        #expect(editor.textView.selectedRange() == NSRange(location: index, length: 1))
        #expect(!overlay.isHidden)
    }

    @Test func onlyTheHandlesTakeClicks() async throws {
        let (editor, index) = try await editorWithPicture()
        editor.textView.setSelectedRange(NSRange(location: index, length: 1))
        let overlay = try #require(editor.coordinator.imageHandles)
        let picture = overlay.convert(overlay.pictureFrame, to: editor.textView)
        #expect(overlay.hitTest(CGPoint(x: picture.maxX, y: picture.maxY)) === overlay)
        #expect(overlay.hitTest(CGPoint(x: picture.minX + 2, y: picture.minY + 1)) === overlay)
        #expect(overlay.hitTest(CGPoint(x: picture.midX, y: picture.midY)) == nil)
    }
}
