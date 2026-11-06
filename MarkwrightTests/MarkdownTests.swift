//
//  MarkdownTests.swift
//  MarkwrightTests
//
//  Markdown to formatted text and back, statistics, and HTML.
//

import AppKit
import Testing

@Suite("Markdown round trips")
struct MarkdownRoundTripTests {
    private func roundTrip(_ markdown: String) -> String {
        TestEnvironment.prepare()
        let renderer = MarkdownRenderer(engine: StyleEngine(style: EditorStyle(theme: ThemeSettings.shared)))
        return MarkdownSerializer.markdown(from: renderer.render(markdown))
    }

    @Test(arguments: [
        ("This is ==important== text.", "This is ==important== text."),
        ("**bold ==hi== bold**", "**bold ==hi== bold**"),
        ("Working on #project/alpha today, see #draft.", "Working on #project/alpha today, see #draft."),
        ("Issue #1 and a#b stay plain.", "Issue #1 and a#b stay plain."),
        ("See [[Other Sheet]] and [[Notes|my notes]].", "See [[Other Sheet]] and [[Notes|my notes]]."),
        ("A claim.[^1] More.[^note]\n\n[^1]: First source.\n[^note]: Second *source*.",
         "A claim.[^1] More.[^note]\n\n[^1]: First source.\n[^note]: Second *source*."),
        ("a \\== b", "a \\=\\= b"),
        ("\\[[not a link]] and \\[^x]", "\\[[not a link]] and \\[^x]"),
        ("# Plan #q4", "# Plan #q4"),
    ])
    func survivesRoundTrip(input: String, expected: String) {
        let once = roundTrip(input)
        #expect(once == expected)
        #expect(roundTrip(once) == once, "a second round trip must change nothing")
    }

    /// Every construct together: nothing may be lost by opening and saving a document.
    @Test func everythingTogetherIsStable() {
        let once = roundTrip(dualDocument)
        #expect(roundTrip(once) == once)
        for piece in ["# Survey of Lakes", "**bold words**", "[link](https://example.com/page)",
                      "[^1]: Footnote definitions collect at the end.", "| Row 30 | 60 |", "- Second item of 7",
                      "[^1]: an example inside a code block"] {
            #expect(once.contains(piece), "\(piece) was lost")
        }
    }

    @Test func commentsAndFrontMatterSurvive() {
        let source = "---\ntitle: Trip\ntags: [a, b]\n---\n\nBody\n\n<!-- a private note -->\n\nMore"
        #expect(roundTrip(source) == source)
    }
}

@Suite("Parsing")
struct ParsingTests {
    @Test func tagWithoutSpaceIsNotHeading() {
        guard case .paragraph = MarkdownParser.parse("#work/alpha today").first else {
            Issue.record("expected a paragraph")
            return
        }
    }

    @Test func headingNeedsSpace() {
        guard case .heading(let level, let text) = MarkdownParser.parse("## Title").first else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 2)
        #expect(text == "Title")
    }

    @Test func blocksKnowTheirSourceLines() {
        let parsed = MarkdownParser.parseWithLines("# A\n\nline one\nline two\n\n```\ncode\n```\n\n| a |\n|---|\n| b |")
        let spans = parsed.filter { if case .blank = $0.block { return false } else { return true } }.map(\.lines)
        #expect(spans == [0..<1, 2..<4, 5..<8, 9..<12])
    }

    @Test func frontMatterHasItsLines() {
        let parsed = MarkdownParser.parseWithLines("---\ntitle: x\n---\n\nBody")
        #expect(parsed.first?.lines == 0..<3)
        #expect(parsed.count == MarkdownParser.parse("---\ntitle: x\n---\n\nBody").count)
    }
}

@Suite("Statistics")
struct StatisticsTests {
    @Test func inlineTags() {
        #expect(TextStatistics.inlineTags(markdown: "x #a/b y #c\n\n- #a") == ["a/b", "c", "a"])
    }

    @Test func wikiLinks() {
        #expect(TextStatistics.wikiLinks(markdown: "[[One]] [[Two|2]] [[One]]") == ["One", "Two"])
    }

    @Test func footnoteIDs() {
        #expect(TextStatistics.footnoteIDs(markdown: "a[^2] b[^x]\n\n[^2]: t\n[^x]: u") == ["2", "x"])
    }

    @Test func plainTextDropsMarkup() {
        #expect(TextStatistics.plain("hi[^1] ==there== [[Sheet|you]] #tag") == "hi there you #tag")
    }

    @Test func attachmentsIncludeWikiLinks() {
        let entries = TextStatistics.attachments(markdown: "see [[Other|o]] and ![i](a.png) and [l](https://x)")
        #expect(entries.map(\.kind) == [.wikiLink, .image, .link])
        #expect(entries[0].target == "Other")
        #expect(entries[0].label == "o")
    }

    @Test func commentsAndFrontMatterAreNotCounted() {
        let stats = TextStatistics.compute(markdown: "---\ntags: [x]\n---\n\none two\n\n<!-- three four five -->")
        #expect(stats.words == 2)
    }
}

@Suite("HTML")
struct HTMLTests {
    private let html = HTMLExporter.body(markdown: "==hi== #tag [[Sheet|S]] note[^1]\n\n[^1]: Source")

    @Test func highlight() { #expect(html.contains("<mark>hi</mark>")) }
    @Test func tag() { #expect(html.contains("<span class=\"tag\">#tag</span>")) }
    @Test func wikiLink() { #expect(html.contains("<a class=\"wikilink\" href=\"Sheet.html\">S</a>")) }

    @Test func footnote() {
        #expect(html.contains("<sup class=\"fnref\" id=\"fnref-1\"><a href=\"#fn-1\">1</a></sup>"))
        #expect(html.contains("<li id=\"fn-1\">Source"))
    }

    @Test func textIsEscaped() {
        let page = HTMLExporter.body(markdown: "a <b>tag</b> & more")
        #expect(!page.contains("<b>tag</b>"))
        #expect(page.contains("&amp;"))
    }
}
