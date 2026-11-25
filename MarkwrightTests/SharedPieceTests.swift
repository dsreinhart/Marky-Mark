//
//  SharedPieceTests.swift
//  MarkwrightTests
//
//  Pieces shared with the iPad app: the iPad guide, footnote jumps in the preview, focus ranges.
//

import Foundation
import Testing

@Suite("iPad guide")
struct PadGuideTests {
    private var guide: String {
        get throws {
            let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Markwright Help", withExtension: "md")
                ?? Bundle.main.url(forResource: "Markwright Help", withExtension: "md"))
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func padSectionComesFirstWithPadIntroduction() throws {
        let original = try guide
        let adapted = HelpGuide.adaptedForPad(original)
        #expect(adapted != original)
        #expect(!adapted.contains("close this tab"))
        #expect(adapted.contains("Welcome to Markwright on iPad and iPhone"))
        let lines = adapted.components(separatedBy: "\n")
        let headings = lines.filter { $0.hasPrefix("## ") }
        #expect(headings.first == "## Markwright for iPad and iPhone")
        #expect(headings.dropFirst().first?.hasPrefix("## 1.") == true)
        #expect(headings.filter { $0.contains("Markwright for iPad") }.count == 1)
        // Everything else survives: same number of sections and the footnote definition.
        #expect(headings.count == original.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count)
        #expect(adapted.contains("[^1]: Footnote definitions collect"))
        #expect(!adapted.contains("---\n\n---"))
    }

    @Test func unexpectedLayoutIsLeftAlone() {
        let text = "# Title\n\nNo rules or iPad section here."
        #expect(HelpGuide.adaptedForPad(text) == text)
    }
}

@Suite("Preview footnote jumps")
struct FootnoteJumpTests {
    private let markdown = """
    # Notes

    Uses `[^a]` in code first, then for real.[^a] And another.[^b]

    ```
    [^b] inside a fence
    ```

    Later mention of [^b] again.

    [^a]: First note.
    [^b]: Second note.
    """

    private func blocks() -> [MarkdownBlock] { MarkdownParser.parse(markdown) }

    @Test func urlRoundTrips() throws {
        let jump = FootnoteJump(direction: .toReference, id: "note one")
        let url = try #require(jump.url)
        #expect(FootnoteJump(url: url) == jump)
        #expect(FootnoteJump(url: URL(string: "https://example.com/def/1")!) == nil)
    }

    @Test func referenceJumpsToDefinition() throws {
        let target = try #require(FootnoteJump(direction: .toDefinition, id: "b").targetBlock(in: markdown))
        guard case .footnoteDefinition(let id, _) = blocks()[target] else { Issue.record("not a definition"); return }
        #expect(id == "b")
    }

    @Test func definitionJumpsBackToFirstRealReference() throws {
        let a = try #require(FootnoteJump(direction: .toReference, id: "a").targetBlock(in: markdown))
        let b = try #require(FootnoteJump(direction: .toReference, id: "b").targetBlock(in: markdown))
        #expect(a == b)   // both first appear in the same paragraph, not the code fence
        guard case .paragraph(let text) = blocks()[a] else { Issue.record("not a paragraph"); return }
        #expect(text.contains("for real"))
        #expect(FootnoteJump(direction: .toReference, id: "missing").targetBlock(in: markdown) == nil)
    }

    @Test func referencesOutsideParagraphsAreFound() throws {
        let doc = """
        ---
        title: Test
        ---

        # Heading with a note[^h]

        - List item with a note[^l]

        > Quoted with a note[^q]

        | A | B |
        |---|---|
        | cell[^t] | 2 |

        [^h]: H.
        [^l]: L.
        [^q]: Q.
        [^t]: T.
        """
        let parsed = MarkdownParser.parse(doc)
        let lines = doc.components(separatedBy: "\n")
        let spans = MarkdownParser.parseWithLines(doc).map(\.lines)
        for id in ["h", "l", "q", "t"] {
            let target = try #require(FootnoteJump(direction: .toReference, id: id).targetBlock(in: doc), "no block for \(id)")
            if case .footnoteDefinition = parsed[target] { Issue.record("\(id) landed on its definition") }
            #expect(lines[spans[target]].joined().contains("[^\(id)]"), "\(id) landed on the wrong block")
        }
    }
}

@Suite("Focus ranges")
struct FocusRangeTests {
    private let text = "First sentence. Second one here.\nNext paragraph." as NSString

    @Test func paragraphIsTheLine() throws {
        let range = try #require(FocusMode.range(in: text, at: 20, mode: .paragraph))
        #expect(text.substring(with: range) == "First sentence. Second one here.\n")
    }

    @Test func sentenceWithinTheLine() throws {
        let range = try #require(FocusMode.range(in: text, at: 20, mode: .sentence))
        #expect(text.substring(with: range).hasPrefix("Second one here."))
        #expect(FocusMode.range(in: text, at: 3, mode: .off) == nil)
        #expect(FocusMode.range(in: "" as NSString, at: 0, mode: .paragraph) == nil)
    }

    @Test func endOfDocument() throws {
        let range = try #require(FocusMode.range(in: text, at: text.length, mode: .paragraph))
        #expect(text.substring(with: range) == "Next paragraph.")
    }
}

@Suite("iPad picture folders")
struct ImageFolderLinksTests {
    private let text = """
    # Mushrooms

    ![Chanterelle](Untitled-images/image-20261120-084924.jpg)
    ![Morel](<Untitled-images/morel.jpg>)
    <img src="Untitled-images/cap.png">
    [ref]: Untitled-images/ref.jpg
    ![New](Mushrooms-images/new.jpg)
    ![Elsewhere](sub/Other-images/x.jpg) ![Web](https://example.com/Web-images/y.jpg)
    ![Up](../Up-images/z.jpg)
    """

    @Test func folderNamesMatchWhatTheIPadWrites() {
        #expect(ImageFolderLinks.folderName(forDocumentNamed: "Untitled") == "Untitled-images")
        #expect(ImageFolderLinks.folderName(forDocumentNamed: "Photo Test") == "Photo-Test-images")
        #expect(ImageFolderLinks.folderName(forDocumentNamed: "  ") == "Untitled-images")
    }

    @Test func findsOnlyFoldersBesideTheDocument() {
        #expect(ImageFolderLinks.linkedFolders(in: text) == ["Untitled-images", "Mushrooms-images"])
        #expect(ImageFolderLinks.linkedFiles(in: text, folder: "Untitled-images")
                == ["image-20261120-084924.jpg", "morel.jpg", "cap.png", "ref.jpg"])
        #expect(ImageFolderLinks.references(text, folder: "Untitled-images"))
        #expect(!ImageFolderLinks.references(text, folder: "Other-images"))
    }

    @Test func rewritesEveryLinkFormAndNothingElse() {
        let moved = ImageFolderLinks.rewrite(text, moves: [
            "Untitled-images/image-20261120-084924.jpg": "Mushrooms-images/image-20261120-084924.jpg",
            "Untitled-images/morel.jpg": "Mushrooms-images/morel.jpg",
            "Untitled-images/cap.png": "Mushrooms-images/cap.png",
            "Untitled-images/ref.jpg": "Mushrooms-images/ref-2.jpg",
        ])
        #expect(!moved.contains("Untitled-images"))
        #expect(moved.contains("![Chanterelle](Mushrooms-images/image-20261120-084924.jpg)"))
        #expect(moved.contains("(<Mushrooms-images/morel.jpg>)"))
        #expect(moved.contains("src=\"Mushrooms-images/cap.png\""))
        #expect(moved.contains("[ref]: Mushrooms-images/ref-2.jpg"))
        #expect(moved.contains("sub/Other-images/x.jpg") && moved.contains("../Up-images/z.jpg"))
    }

    @Test func recognisesOnlyNamesTheIPadGives() {
        #expect(ImageFolderLinks.isSavedPictureName("image-20261120-084924.jpg"))
        #expect(ImageFolderLinks.isSavedPictureName("Chanterelle-20261120-084924-2.png"))
        #expect(!ImageFolderLinks.isSavedPictureName("holiday.jpg"))
        #expect(!ImageFolderLinks.isSavedPictureName("IMG_2024.HEIC"))
    }

    @Test func uniqueNamesCountUp() {
        let taken: Set = ["a.jpg", "a-2.jpg"]
        #expect(ImageFolderLinks.uniqueFileName("b.jpg") { taken.contains($0) } == "b.jpg")
        #expect(ImageFolderLinks.uniqueFileName("a.jpg") { taken.contains($0) } == "a-3.jpg")
    }
}

@Suite("Table columns (iPad and iPhone)")
struct TableColumnTests {
    @Test func shortColumnsStayShortAndTheRestIsShared() {
        // Day | Drive | Stop for the night, on a phone-width column.
        let layout = TableColumns.layout(naturalWidths: [30, 160, 130], width: 370)
        #expect(layout.scale == 1)
        #expect(layout.stops.count == 2)
        #expect(layout.stops[0] < 70, "the narrow first column isn't given a third of the width")
        // Every column starts after the previous one's widest cell.
        #expect(layout.stops[0] >= TableColumns.leading + 30 + TableColumns.gap)
        #expect(layout.stops[1] >= layout.stops[0] + 160 + TableColumns.gap)
    }

    @Test func tooWideScalesDownToFitButNotTooFar() {
        let fits = TableColumns.layout(naturalWidths: [120, 80, 70, 90], width: 340)
        #expect(fits.scale < 1)
        let used = (120 + 80 + 70 + 90) * fits.scale + TableColumns.gap * 4
        #expect(used <= 340.5, "scaled cells and gaps fit the width")
        let huge = TableColumns.layout(naturalWidths: [400, 400, 400], width: 340)
        #expect(huge.scale == TableColumns.minimumScale, "text never shrinks below the minimum")
    }

    @Test func roomyTablesKeepFullSize() {
        let layout = TableColumns.layout(naturalWidths: [40, 60], width: 700)
        #expect(layout.scale == 1)
        #expect(layout.stops.first ?? 0 > 40 + TableColumns.gap, "spare room is shared out, not left at the end")
    }
}

