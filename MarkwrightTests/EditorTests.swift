//
//  EditorTests.swift
//  MarkwrightTests
//
//  Editing through real text views: the formatted editor, raw formatting commands and the controller.
//

import AppKit
import Testing

@Suite("Formatted editor")
struct FormattedEditorTests {
    @Test func highlightTogglesOnAndOff() {
        let editor = FormattedEditor()
        editor.load("Mark this word please.")
        editor.select("word")
        editor.coordinator.toggleInline(.mmHighlight)
        #expect(editor.text == "Mark this ==word== please.")
        editor.coordinator.toggleInline(.mmHighlight)
        #expect(editor.text == "Mark this word please.")
    }

    @Test func typedTagIsStyled() {
        let editor = FormattedEditor()
        editor.load("Tagging")
        editor.cursor(after: "Tagging")
        editor.type(" #ideas/app and")
        #expect(editor.text == "Tagging #ideas/app and")
        let storage = editor.textView.textStorage!
        let tagged = (0..<storage.length).filter { storage.attribute(.mmTag, at: $0, effectiveRange: nil) != nil }.count
        #expect(tagged == "#ideas/app".count)
    }

    @Test func typedTagAtStartStaysParagraph() {
        let editor = FormattedEditor()
        editor.load("")
        editor.type("#work/alpha today")
        #expect(editor.text == "#work/alpha today")
        #expect(editor.textView.textStorage!.attribute(.mmTag, at: 2, effectiveRange: nil) != nil)
    }

    @Test func typedWikiLinkConverts() {
        let editor = FormattedEditor()
        editor.load("Link to")
        editor.cursor(after: "Link to")
        editor.type(" [[Other Sheet]] now")
        #expect(editor.text == "Link to [[Other Sheet]] now")
        var links = 0
        let storage = editor.textView.textStorage!
        storage.enumerateAttribute(.mmWikiLink, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        #expect(links == 1)
    }

    @Test func completionCommitClosesLink() {
        let editor = FormattedEditor()
        editor.load("")
        editor.type("See [[Oth")
        let partial = NSRange(location: 6, length: 3)
        editor.textView.insertCompletion("Other Sheet", forPartialWordRange: partial,
                                         movement: NSTextMovement.other.rawValue, isFinal: false)
        #expect(editor.textView.selectedRange().length > 0, "the preview selects the rest of the name")
        editor.textView.insertCompletion("Other Sheet", forPartialWordRange: partial,
                                         movement: NSTextMovement.return.rawValue, isFinal: true)
        #expect(editor.text == "See [[Other Sheet]]")
    }

    @Test func footnotesNumberThemselves() {
        let editor = FormattedEditor()
        editor.load("A claim here.\n\nSecond paragraph.")
        editor.cursor(after: "claim")
        editor.coordinator.insertFootnote()
        #expect(editor.text == "A claim[^1] here.\n\nSecond paragraph.\n\n[^1]: ")
        editor.type("Source text")
        #expect(editor.text.hasSuffix("[^1]: Source text"))
        editor.cursor(after: "here")
        editor.coordinator.insertFootnote()
        #expect(editor.text.contains("here[^2]."))
        #expect(editor.text.hasSuffix("[^2]: "))
    }

    @Test func footnoteKeepsSelectedText() {
        let editor = FormattedEditor()
        editor.load("A ==word== here.")
        editor.select("word")
        editor.coordinator.insertFootnote()
        #expect(editor.text.hasPrefix("A ==word==[^1] here.") || editor.text.hasPrefix("A ==word[^1]== here."))
    }

    @Test func foldingCoversTheSectionOnly() {
        let editor = FormattedEditor()
        editor.load("# One\n\nbody one\n\n## Sub\n\nsub body\n\n# Two\n\nbody two")
        editor.cursor(after: "One")
        editor.coordinator.toggleFold()
        #expect(editor.coordinator.foldedRanges.count == 1)
        let hidden = editor.textView.string.ns.substring(with: editor.coordinator.foldedRanges[0])
        #expect(hidden.contains("sub body"))
        #expect(!hidden.contains("body two"))
        #expect(editor.controller.state.folded)

        editor.type("!")
        #expect(editor.text.hasPrefix("# One!"))
        #expect(editor.text.contains("body one"), "folding must never remove text")

        editor.coordinator.toggleFold()
        #expect(editor.coordinator.foldedRanges.isEmpty)
    }
}

@Suite("Footnote clicks")
struct FootnoteClickTests {
    @Test func formattedClickGoesToDefinitionAndBack() throws {
        let editor = FormattedEditor()
        editor.load("A note.[^1] More text.\n\nSecond paragraph.\n\n[^1]: Source here")
        let view = editor.textView
        let storage = view.textStorage!
        view.layoutManager!.ensureLayout(for: view.textContainer!)

        var reference = NSNotFound
        storage.enumerateAttribute(.mmFootnoteRef, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { reference = range.location; stop.pointee = true }
        }
        try #require(reference != NSNotFound)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.coordinator.handleMouseDown(mouseDown(on: view, at: reference)))
        #expect(view.selectedText == "Source here")

        var label = NSNotFound
        storage.enumerateAttribute(.mmMarker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value as? Bool == true,
               let block = storage.attribute(.mmBlock, at: range.location, effectiveRange: nil) as? BlockInfo,
               case .footnote = block.kind { label = range.location }
        }
        try #require(label != NSNotFound)
        #expect(editor.coordinator.handleMouseDown(mouseDown(on: view, at: label)))
        #expect(view.selectedRange().location == reference)

        #expect(!editor.coordinator.handleMouseDown(mouseDown(on: view, at: 2)), "ordinary text is left alone")
    }

    private func rawView(_ text: String) -> (MarkwrightTextView, NSWindow) {
        TestEnvironment.prepare()
        let view = MarkwrightTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        view.handlesFootnoteClicks = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.string = text
        return (view, window)
    }

    @Test func rawCommandClickGoesBothWays() {
        let (view, window) = rawView("Text[^1] more\n\nBody\n\n[^1]: Def\n[^2]: Other")
        defer { _ = window }
        let reference = view.string.ns.range(of: "[^1]")
        let definition = view.string.ns.range(of: "[^1]:")
        #expect(view.jumpFootnote(at: mouseDown(on: view, at: reference.location + 2, flags: .command)))
        #expect(view.selectedRange() == definition)
        #expect(view.jumpFootnote(at: mouseDown(on: view, at: definition.location + 1, flags: .command)))
        #expect(view.selectedRange() == reference)
        #expect(!view.jumpFootnote(at: mouseDown(on: view, at: 1, flags: .command)), "ordinary text is left alone")
    }

    /// The guide's own examples once sent this to a code block.
    @Test func rawCommandClickSkipsCode() {
        let (view, window) = rawView("Use `[^1]` like this.[^1]\n\n```\n[^1]: example in code\n```\n\n[^1]: Real definition")
        defer { _ = window }
        let definition = view.string.ns.range(of: "[^1]: Real")
        let reference = view.string.ns.range(of: "this.[^1]")
        #expect(view.jumpFootnote(at: mouseDown(on: view, at: reference.location + 6, flags: .command)))
        #expect(view.selectedRange() == NSRange(location: definition.location, length: 5))
        #expect(view.jumpFootnote(at: mouseDown(on: view, at: definition.location + 1, flags: .command)))
        #expect(view.selectedRange().location == reference.location + 5)
        #expect(!view.jumpFootnote(at: mouseDown(on: view, at: 6, flags: .command)), "a click inside a code span does nothing")
    }

    @Test func codeRangesFindBlocksAndSpans() {
        #expect(MarkwrightTextView.codeRanges(in: "a `b` c\n```\nx\n```\nd").count == 2)
    }
}

@Suite("Raw formatting")
struct RawMarkupTests {
    @Test func boldWrapsAndUnwraps() {
        let raw = RawEditor()
        raw.load("make this bold please")
        raw.select("this bold")
        RawMarkup.wrap(raw.textView, prefix: "**", suffix: "**", placeholder: "bold")
        #expect(raw.text == "make **this bold** please")
        #expect(raw.selected == "this bold")
        RawMarkup.wrap(raw.textView, prefix: "**", suffix: "**", placeholder: "bold")
        #expect(raw.text == "make this bold please", "unwraps from the inner selection")

        raw.load("x **bold** y")
        raw.select("**bold**")
        RawMarkup.wrap(raw.textView, prefix: "**", suffix: "**", placeholder: "bold")
        #expect(raw.text == "x bold y", "unwraps from the outer selection")
    }

    @Test func emptySelectionInsertsPlaceholder() {
        let raw = RawEditor()
        raw.load("word")
        raw.cursor(at: 4)
        RawMarkup.wrap(raw.textView, prefix: "==", suffix: "==", placeholder: "highlight")
        #expect(raw.text == "word==highlight==")
        #expect(raw.selected == "highlight")
    }

    @Test func listsToggle() {
        let raw = RawEditor()
        let bullets = ["* ", "+ ", "- [ ] ", "- [x] ", "1. "]
        raw.load("one\ntwo\nthree\n")
        raw.textView.setSelectedRange(NSRange(location: 1, length: 6))
        RawMarkup.togglePrefix(raw.textView, "- ", alternatives: bullets)
        #expect(raw.text == "- one\n- two\nthree\n")
        RawMarkup.togglePrefix(raw.textView, "- ", alternatives: bullets)
        #expect(raw.text == "one\ntwo\nthree\n")

        raw.textView.setSelectedRange(NSRange(location: 0, length: 13))
        RawMarkup.toggleNumbered(raw.textView)
        #expect(raw.text == "1. one\n2. two\n3. three\n")
        RawMarkup.togglePrefix(raw.textView, "- [ ] ", alternatives: ["- [x] ", "- ", "* ", "+ ", "1. "])
        #expect(raw.text == "- [ ] one\n- [ ] two\n- [ ] three\n")
    }

    @Test func headingsSetAndClear() {
        let raw = RawEditor()
        raw.load("Title\nbody")
        raw.cursor(at: 2)
        RawMarkup.setHeading(raw.textView, level: 2)
        #expect(raw.text == "## Title\nbody")
        RawMarkup.setHeading(raw.textView, level: 0)
        #expect(raw.text == "Title\nbody")
    }

    @Test func blockGetsBlankLinesAround() {
        let raw = RawEditor()
        raw.load("para one\npara two")
        raw.cursor(at: 8)
        RawMarkup.insertBlock(raw.textView, "---")
        #expect(raw.text == "para one\n\n---\n\npara two")
    }

    @Test func footnotesNumberThemselves() {
        let raw = RawEditor()
        raw.load("A claim here.")
        raw.cursor(at: 7)
        RawMarkup.insertFootnote(raw.textView)
        #expect(raw.text == "A claim[^1] here.\n\n[^1]: ")
        #expect(raw.textView.selectedRange().location == raw.text.ns.length)
        raw.cursor(at: 1)
        RawMarkup.insertFootnote(raw.textView)
        #expect(raw.text.hasPrefix("A[^2] claim[^1]"))
        #expect(raw.text.hasSuffix("[^1]: \n[^2]: "))
    }

    @Test func footnoteKeepsSelectedText() {
        let raw = RawEditor()
        raw.load("A ==word== here.")
        raw.textView.setSelectedRange(NSRange(location: 4, length: 4))
        RawMarkup.insertFootnote(raw.textView)
        #expect(raw.text.hasPrefix("A ==word[^1]== here."))
    }
}

@Suite("Editor controller")
struct ControllerTests {
    private func rawController(_ text: String) -> (RichEditorController, RawEditor) {
        let raw = RawEditor()
        raw.load(text)
        let controller = RichEditorController()
        controller.rawTextView = raw.textView
        controller.isActive = true
        return (controller, raw)
    }

    @Test func routesToRawWithoutFormattedEditor() {
        let (controller, raw) = rawController("abc")
        raw.select("abc")
        controller.toggleBold()
        #expect(raw.text == "**abc**")
        controller.requestLink()
        #expect(raw.text == "**[abc](https://)**")
    }

    /// SwiftUI can make the incoming editor before it dismantles the outgoing one.
    @Test func activeStateSurvivesEditorChange() {
        let raw = RawEditor()
        let controller = RichEditorController()
        controller.rawTextView = raw.textView
        controller.refreshActive()
        controller.coordinator = nil
        controller.refreshActive()
        #expect(controller.isActive)
        controller.rawTextView = nil
        controller.refreshActive()
        #expect(!controller.isActive)
    }

    @Test func jumpCyclesAndWraps() {
        let (controller, raw) = rawController("x #t one\n#t two\nend")
        raw.cursor(at: 0)
        controller.jump(toText: "#t")
        #expect(raw.textView.selectedRange() == NSRange(location: 2, length: 2))
        controller.jump(toText: "#t")
        #expect(raw.textView.selectedRange() == NSRange(location: 9, length: 2))
        controller.jump(toText: "#t")
        #expect(raw.textView.selectedRange() == NSRange(location: 2, length: 2))
    }

    @Test func jumpFromStartIgnoresCaseAndGoesBackwards() {
        let (controller, raw) = rawController("Alpha action here.\n\nMore Action later.")
        raw.cursor(at: 8)
        controller.jump(toText: "ACTION", fromStart: true, options: [.caseInsensitive, .diacriticInsensitive])
        #expect(raw.textView.selectedRange() == NSRange(location: 6, length: 6))
        controller.jump(toText: "action", options: [.caseInsensitive])
        #expect(raw.textView.selectedRange().location > 12)
        controller.jump(toText: "action", backwards: true, options: [.caseInsensitive])
        #expect(raw.textView.selectedRange() == NSRange(location: 6, length: 6))
        controller.jump(toText: "action", backwards: true, options: [.caseInsensitive])
        #expect(raw.textView.selectedRange().location > 12, "going back from the first wraps to the last")
    }

    @Test func matchCount() {
        #expect(RichEditorController.matchCount(of: "ACTION", in: "action and Action") == 2)
        #expect(RichEditorController.matchCount(of: "", in: "anything") == 0)
        #expect(RichEditorController.matchCount(of: "cafe", in: "café") == 1, "accents are ignored like the search")
    }
}
