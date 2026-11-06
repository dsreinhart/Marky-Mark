//
//  DualPaneTests.swift
//  MarkwrightTests
//
//  The source map and everything dual mode builds on it.
//

import AppKit
import Testing

@Suite("Source map")
struct SourceMapTests {
    private func assertPhrases(_ map: SourceMap, raw: NSString, rendered: NSString, _ phrases: [String],
                               sourceLocation: SourceLocation = #_sourceLocation) {
        for phrase in phrases {
            let inRaw = raw.range(of: phrase)
            let inRendered = rendered.range(of: phrase)
            #expect(inRaw.location != NSNotFound && inRendered.location != NSNotFound, "\(phrase) missing", sourceLocation: sourceLocation)
            #expect(map.renderedRange(forRaw: inRaw, raw: raw, rendered: rendered) == inRendered, "\(phrase) to formatted", sourceLocation: sourceLocation)
            #expect(map.rawRange(forRendered: inRendered, raw: raw, rendered: rendered) == inRaw, "\(phrase) to raw", sourceLocation: sourceLocation)
        }
    }

    private let phrases = ["Working in Dual", "here in action", "Working with sheets", "Keyboard shortcuts",
                           "Column", "Footnote definitions collect"]

    @Test func fromRendererLandsOnTheSameText() {
        let dual = DualEditors()
        let map = dual.rich.sourceMap
        let raw = dual.rawView.string.ns
        let rendered = dual.richView.string.ns
        #expect(map.entries.allSatisfy { NSMaxRange($0.raw) <= raw.length && NSMaxRange($0.rendered) <= rendered.length })
        #expect(zip(map.entries, map.entries.dropFirst()).allSatisfy { $0.raw.location <= $1.raw.location && $0.rendered.location <= $1.rendered.location })
        assertPhrases(map, raw: raw, rendered: rendered, phrases)
    }

    @Test func fromSerializerLandsOnTheSameText() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.richView)
        let at = dual.richView.string.ns.range(of: "Working in Dual").location
        dual.richView.setSelectedRange(NSRange(location: at, length: 0))
        dual.richView.insertText("X", replacementRange: NSRange(location: at, length: 0))
        #expect(dual.text.contains("XWorking in Dual"))

        let map = dual.rich.sourceMap
        let raw = dual.text.ns
        let rendered = dual.richView.string.ns
        #expect(zip(map.entries, map.entries.dropFirst()).allSatisfy { $0.raw.location <= $1.raw.location })
        #expect(map.entries.allSatisfy { NSMaxRange($0.raw) <= raw.length && NSMaxRange($0.rendered) <= rendered.length })
        assertPhrases(map, raw: raw, rendered: rendered, ["XWorking in Dual", "here in action", "Column", "Footnote definitions collect"])
    }

    @Test func stepsOverInlineMarkup() {
        let dual = DualEditors()
        let raw = dual.rawView.string.ns
        let bold = raw.range(of: "**bold words**")
        let inner = NSRange(location: bold.location + 2, length: 10)
        let mapped = dual.rich.sourceMap.renderedRange(forRaw: inner, raw: raw, rendered: dual.richView.string.ns)
        #expect(dual.richView.string.ns.substring(with: mapped) == "bold words")
    }

    @Test func wordInsideHiddenAddressStaysInItsBlock() {
        let map = SourceMap(entries: [.init(raw: NSRange(location: 0, length: 26), rendered: NSRange(location: 0, length: 4))])
        let hit = map.renderedMatch(forRaw: NSRange(location: 15, length: 4), needle: "site", options: [],
                                    raw: "[link](https://site.com/x)", rendered: "link")
        #expect(NSMaxRange(hit) <= 4)
    }

    @Test func repeatedWordMapsToTheSameOccurrence() {
        let raw: NSString = "**word** one word two word"
        let rendered: NSString = "word one word two word"
        let map = SourceMap(entries: [.init(raw: NSRange(location: 0, length: raw.length), rendered: NSRange(location: 0, length: rendered.length))])
        let second = raw.range(of: "word", range: NSRange(location: 8, length: raw.length - 8))
        let expected = rendered.range(of: "word", range: NSRange(location: 4, length: rendered.length - 4))
        #expect(map.renderedMatch(forRaw: second, needle: "word", options: [], raw: raw, rendered: rendered) == expected)
    }

    /// Occurrences are counted through the source, including any hidden inside a link address,
    /// so a match after one lands on the next visible occurrence in the formatted pane.
    @Test func hiddenOccurrenceDoesNotShiftTheMatch() {
        let raw: NSString = "A [link](https://word.example) then word and word"
        let rendered: NSString = "A link then word and word"
        let map = SourceMap(entries: [.init(raw: NSRange(location: 0, length: raw.length), rendered: NSRange(location: 0, length: rendered.length))])
        let firstVisibleInRaw = raw.range(of: "word", range: NSRange(location: 30, length: raw.length - 30))
        let firstVisible = rendered.range(of: "word")
        withKnownIssue("Flashes the following occurrence in the formatted pane") {
            #expect(map.renderedMatch(forRaw: firstVisibleInRaw, needle: "word", options: [], raw: raw, rendered: rendered) == firstVisible)
        }
    }

    @Test func emptyMapIsSafe() {
        let map = SourceMap()
        #expect(map.renderedLocation(forRaw: 5, raw: "hello", rendered: "hello") == 0)
        #expect(map.rawLocation(forRendered: 5, raw: "hello", rendered: "hello") == 0)
    }

    @Test func interpolationIsLinearAndClamped() {
        let from: [CGFloat] = [0, 100, 200]
        let to: [CGFloat] = [0, 300, 400]
        #expect(DualPaneSync.interpolate(-5, from: from, to: to) == 0)
        #expect(DualPaneSync.interpolate(50, from: from, to: to) == 150)
        #expect(DualPaneSync.interpolate(150, from: from, to: to) == 350)
        #expect(DualPaneSync.interpolate(999, from: from, to: to) == 400)
        #expect(DualPaneSync.interpolate(5, from: [], to: []) == 0)
    }
}

@Suite("Dual scrolling")
struct DualScrollingTests {
    @Test func panesSitAtTheScrollOrigin() {
        let dual = DualEditors()
        #expect(dual.controller.isDual)
        #expect(dual.controller.paneSync.isLinked)
        #expect(dual.rawView.frame.minY == 0)
        #expect(dual.richView.frame.minY == 0)
    }

    @Test func eitherPaneLeadsToTheSameHeading() {
        let dual = DualEditors()
        let raw = dual.rawView.string.ns
        let rich = dual.richView.string.ns

        dual.controller.paneSync.setDriver(dual.rawView)
        let shortcuts = "Keyboard shortcuts"
        dual.scroll(dual.rawScroll, to: DualPaneSync.scrollY(of: raw.range(of: shortcuts).location, in: dual.rawView))
        let expectedRich = DualPaneSync.scrollY(of: rich.range(of: shortcuts).location, in: dual.richView)
        #expect(abs(dual.richScroll.contentView.bounds.minY - expectedRich) < 2)

        dual.controller.paneSync.setDriver(dual.richView)
        let sheets = "Working with sheets"
        dual.scroll(dual.richScroll, to: DualPaneSync.scrollY(of: rich.range(of: sheets).location, in: dual.richView))
        let expectedRaw = DualPaneSync.scrollY(of: raw.range(of: sheets).location, in: dual.rawView)
        #expect(abs(dual.rawScroll.contentView.bounds.minY - expectedRaw) < 2)
    }

    @Test func bothReachTheEndsTogether() {
        let dual = DualEditors()
        dual.controller.paneSync.setDriver(dual.rawView)
        dual.scroll(dual.rawScroll, to: DualPaneSync.maxScrollY(of: dual.rawView))
        #expect(abs(dual.richScroll.contentView.bounds.minY - DualPaneSync.maxScrollY(of: dual.richView)) < 2)
        dual.scroll(dual.rawScroll, to: 0)
        #expect(dual.richScroll.contentView.bounds.minY < 1)
    }

    @Test func followingPaneDoesNotPushBack() {
        let dual = DualEditors()
        dual.controller.paneSync.setDriver(dual.rawView)
        dual.scroll(dual.rawScroll, to: 1000)
        let before = dual.rawScroll.contentView.bounds.minY
        dual.scroll(dual.richScroll, to: dual.richScroll.contentView.bounds.minY + 300)
        #expect(dual.rawScroll.contentView.bounds.minY == before)
    }

    @Test func followsInOrder() {
        let dual = DualEditors()
        dual.controller.paneSync.setDriver(dual.rawView)
        var positions: [CGFloat] = []
        for y in stride(from: CGFloat(0), to: DualPaneSync.maxScrollY(of: dual.rawView), by: 200) {
            dual.scroll(dual.rawScroll, to: y)
            positions.append(dual.richScroll.contentView.bounds.minY)
        }
        #expect(positions.count > 3)
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 + 0.5 })
    }
}

@Suite("Dual editing")
struct DualEditingTests {
    @Test func rawEditReachesFormattedAfterThePause() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.rawView)
        #expect(dual.controller.rawHasFocus)
        dual.controller.paneSync.setDriver(dual.rawView)
        dual.scroll(dual.rawScroll, to: 2000)
        let selection = NSRange(location: 40, length: 3)
        dual.richView.setSelectedRange(selection)
        let at = dual.rawView.string.ns.range(of: "Working in Dual").location
        dual.rawView.setSelectedRange(NSRange(location: at, length: 0))
        dual.rawView.insertText("New ", replacementRange: NSRange(location: at, length: 0))
        dual.rawEdited()
        #expect(dual.text.contains("New Working in Dual"))

        let sent = dual.text
        dual.rich.receive(dual.text)
        #expect(!dual.richView.string.contains("New Working in Dual"), "waits while the other pane is typed in")
        let y = dual.richScroll.contentView.bounds.minY
        dual.rich.flushPendingText()
        #expect(dual.richView.string.contains("New Working in Dual"))
        #expect(dual.text == sent, "showing the text must not rewrite it")
        #expect(dual.richView.selectedRange() == selection)
        #expect(abs(dual.richScroll.contentView.bounds.minY - y) < 60)
    }

    @Test func pendingTextArrivesOnItsOwn() async {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.rawView)
        dual.text += "\n\nAdded later"
        dual.rich.receive(dual.text)
        #expect(await waitUntil { dual.richView.string.contains("Added later") })
    }

    @Test func takingFocusBringsThePaneUpToDate() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.rawView)
        dual.text += "\n\nAdded just before the click"
        dual.rich.receive(dual.text)
        dual.window.makeFirstResponder(dual.richView)
        #expect(dual.richView.string.contains("Added just before the click"))
        #expect(!dual.controller.rawHasFocus)
    }

    @Test func formattedEditReachesRaw() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.richView)
        let at = dual.richView.string.ns.range(of: "Working in Dual").location
        dual.richView.setSelectedRange(NSRange(location: at, length: 0))
        dual.richView.insertText("X", replacementRange: NSRange(location: at, length: 0))
        #expect(dual.text.contains("XWorking in Dual"))
        dual.raw.receive(dual.text)
        dual.raw.flushPendingText()
        #expect(dual.rawView.string == dual.text)
    }

    /// A shortened text must not leave a selection past its end.
    @Test func shorterTextClampsTheSelection() {
        let dual = DualEditors("A longer piece of text")
        dual.window.makeFirstResponder(dual.richView)
        dual.rawView.setSelectedRange(NSRange(location: 20, length: 2))
        dual.raw.receive("Short")
        dual.raw.flushPendingText()
        #expect(dual.rawView.string == "Short")
        #expect(NSMaxRange(dual.rawView.selectedRange()) <= 5)
    }

    @Test func foldsSurviveAnEditInTheOtherPane() {
        let dual = DualEditors("# One\n\nbody one\n\n# Two\n\nbody two")
        dual.window.makeFirstResponder(dual.richView)
        dual.richView.setSelectedRange(NSRange(location: 1, length: 0))
        dual.rich.toggleFold()
        #expect(dual.rich.foldedRanges.count == 1)
        dual.window.makeFirstResponder(dual.rawView)
        dual.rich.reload("# One\n\nbody one changed\n\n# Two\n\nbody two")
        #expect(dual.rich.foldedRanges.count == 1)
        #expect(dual.richView.string.ns.substring(with: dual.rich.foldedRanges[0]).contains("changed"))
    }

    @Test func undoStaysWithItsPane() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.rawView)
        #expect(dual.rawView.undoManager !== dual.richView.undoManager)
        let undo = dual.rawView.undoManager
        #expect(undo != nil)
        undo?.removeAllActions()
        undo?.groupsByEvent = false
        undo?.beginUndoGrouping()
        dual.rawView.insertText("ZZ", replacementRange: NSRange(location: 0, length: 0))
        undo?.endUndoGrouping()
        dual.rich.receive(dual.rawView.string)
        dual.rich.flushPendingText()
        #expect(undo?.canUndo == true, "a reload of the other pane leaves this pane's history")
        undo?.groupsByEvent = true
        #expect(dual.rawView.tryToPerform(NSSelectorFromString("undo:"), with: nil), "the Undo command reaches this pane")
        #expect(!dual.rawView.string.hasPrefix("ZZ"))
    }

    @Test func editingOneClearsTheOthersHistory() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.richView)
        dual.rawView.undoManager?.registerUndo(withTarget: dual.rawView) { _ in }
        #expect(dual.rawView.undoManager?.canUndo == true)
        dual.raw.receive(dual.text + "\n\nchanged elsewhere")
        dual.raw.flushPendingText()
        #expect(dual.rawView.undoManager?.canUndo == false, "its history describes text that is gone")
    }

    @Test func formattingFollowsTheCursor() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.rawView)
        dual.rawView.setSelectedRange(dual.rawView.string.ns.range(of: "Working with sheets"))
        dual.controller.toggleBold()
        #expect(dual.rawView.string.contains("**Working with sheets**"))
    }

    @Test func foldAndIndentDoNothingFromRaw() {
        let dual = DualEditors("# One\n\nbody")
        dual.window.makeFirstResponder(dual.rawView)
        dual.controller.toggleFold()
        #expect(dual.rich.foldedRanges.isEmpty)
    }
}

@Suite("Dual jumps")
struct DualJumpTests {
    private let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    @Test func searchSelectsTheMatchInBothPanes() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.richView)
        dual.controller.jump(toText: "action", fromStart: true, options: options)
        #expect(dual.rawView.selectedText.lowercased() == "action")
        #expect(dual.richView.selectedText.lowercased() == "action")
        let mapped = dual.rich.sourceMap.renderedLocation(forRaw: dual.rawView.selectedRange().location,
                                                          raw: dual.rawView.string.ns, rendered: dual.richView.string.ns)
        #expect(abs(mapped - dual.richView.selectedRange().location) < 2, "the same occurrence")
        #expect(dual.window.firstResponder === dual.richView, "the cursor stays in the pane it was in")
    }

    @Test func nextAndPreviousStepThroughMatches() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.richView)
        dual.controller.jump(toText: "footnote", fromStart: true, options: options)
        let first = dual.rawView.selectedRange().location
        dual.controller.jump(toText: "footnote", options: options)
        #expect(dual.rawView.selectedRange().location > first)
        #expect(dual.richView.selectedText.lowercased() == "footnote")
        dual.controller.jump(toText: "footnote", backwards: true, options: options)
        #expect(dual.rawView.selectedRange().location == first)
    }

    @Test func formattedFootnoteClickShowsInBothPanes() throws {
        let dual = DualEditors()
        let storage = dual.richView.textStorage!
        var reference = NSNotFound
        storage.enumerateAttribute(.mmFootnoteRef, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { reference = range.location; stop.pointee = true }
        }
        try #require(reference != NSNotFound)
        _ = dual.rich.handleMouseDown(mouseDown(on: dual.richView, at: reference))
        #expect(dual.richView.selectedText.hasPrefix("Footnote definitions collect"))
        #expect(dual.rawView.selectedText.hasPrefix("Footnote definitions collect"))
    }

    @Test func rawFootnoteClickShowsInBothPanes() throws {
        let dual = DualEditors()
        let storage = dual.richView.textStorage!
        var reference = NSNotFound
        storage.enumerateAttribute(.mmFootnoteRef, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { reference = range.location; stop.pointee = true }
        }
        let rawText = dual.rawView.string.ns
        let inSource = rawText.range(of: "in action.[^1]")
        let definition = rawText.range(of: "[^1]: Footnote definitions")

        #expect(dual.rawView.jumpFootnote(at: mouseDown(on: dual.rawView, at: definition.location + 1, flags: .command)))
        #expect(dual.rawView.selectedRange().location == inSource.location + 10)
        #expect(dual.richView.selectedRange().location == reference)

        #expect(dual.rawView.jumpFootnote(at: mouseDown(on: dual.rawView, at: inSource.location + 12, flags: .command)))
        #expect(dual.richView.selectedText.hasPrefix("Footnote definitions"), "the label moves onto the note's text")
    }
}

@Suite("Keeping the place across modes")
struct ModeChangeTests {
    @Test func dualToFormattedKeepsPlaceAndSelection() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.rawView)
        dual.controller.paneSync.setDriver(dual.rawView)
        let name = "Working with sheets"
        let at = dual.rawView.string.ns.range(of: name).location
        let inRich = dual.richView.string.ns.range(of: name).location
        dual.scroll(dual.rawScroll, to: DualPaneSync.scrollY(of: at, in: dual.rawView))
        dual.rawView.setSelectedRange(NSRange(location: at + 3, length: 4))

        dual.controller.editorsWillChange()
        #expect(dual.controller.pendingPosition != nil)
        dual.rawScroll.removeFromSuperview()
        dual.controller.rawTextView = nil
        dual.controller.rawCoordinator = nil
        dual.controller.refreshActive()
        #expect(!dual.controller.isDual)
        #expect(dual.controller.restorePosition())
        #expect(dual.controller.pendingPosition == nil)

        #expect(abs(dual.richScroll.contentView.bounds.minY - DualPaneSync.scrollY(of: inRich, in: dual.richView)) < 30)
        #expect(dual.richView.selectedText == "king")
    }

    @Test func formattedToRawKeepsPlace() {
        let dual = DualEditors()
        // Start with only the formatted pane.
        dual.rawScroll.removeFromSuperview()
        dual.controller.rawTextView = nil
        dual.controller.rawCoordinator = nil
        dual.controller.refreshActive()
        let name = "Keyboard shortcuts"
        dual.scroll(dual.richScroll, to: DualPaneSync.scrollY(of: dual.richView.string.ns.range(of: name).location, in: dual.richView))
        dual.window.makeFirstResponder(dual.richView)

        dual.controller.editorsWillChange()
        dual.addFreshRawPane()
        dual.controller.editorsWillChange()   // SwiftUI may also dismantle after making; the place is kept once
        dual.richScroll.removeFromSuperview()
        dual.controller.coordinator = nil
        dual.controller.refreshActive()
        dual.rawView.layoutManager!.ensureLayout(for: dual.rawView.textContainer!)
        dual.rawView.sizeToFit()
        #expect(dual.controller.restorePosition())

        let target = DualPaneSync.scrollY(of: dual.rawView.string.ns.range(of: name).location, in: dual.rawView)
        #expect(abs(dual.rawScroll.contentView.bounds.minY - target) < 30)
        #expect(!dual.controller.isDual)
        #expect(!dual.controller.paneSync.isLinked)
    }

    @Test func topOfDocumentStaysAtTheTop() {
        let dual = DualEditors()
        let position = dual.controller.position(of: dual.rawView)
        #expect(position?.top == nil, "the very top is remembered as the top, not as a line")
    }

    @Test func positionsAreInSourceTerms() {
        let dual = DualEditors()
        dual.window.makeFirstResponder(dual.richView)
        let name = "Working with sheets"
        let inRich = dual.richView.string.ns.range(of: name).location
        dual.controller.paneSync.setDriver(dual.richView)
        dual.scroll(dual.richScroll, to: DualPaneSync.scrollY(of: inRich, in: dual.richView))
        let position = dual.controller.position(of: dual.richView)
        let source = dual.rawView.string.ns.range(of: name)
        let top = try! #require(position?.top)
        #expect(abs(top - source.location) < 40, "\(top) vs \(source.location)")
    }
}
