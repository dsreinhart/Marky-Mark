//
//  PadRichCoordinator.swift
//  Markwright iPad
//
//  The editing logic of the iPad's formatted editor (Formatted and Dual layouts). Ported from the
//  Mac's formatted editor (Markwright/Editor/RichMarkdownEditorView.swift): the text stores semantic
//  attributes, every edit is tidied so they stay consistent, and the bound Markdown is rewritten
//  from them. What differs is UIKit's: keystrokes arrive through `shouldChangeTextIn` (no
//  `doCommandBy`), the coordinator records its own changes in the text view's undo history, and
//  tables are shown read only (iPadOS has no text tables). The UIKit side is PadRichEditorView.swift.
//

import SwiftUI
import UIKit

@MainActor
final class PadRichCoordinator: NSObject {
    var parent: PadRichEditorView
    let engine: StyleEngine
    weak var textView: PadRichTextView?
    var baseURL: URL?
    private(set) var lastKnownText = ""
    /// Connects `lastKnownText` to the text in the view (Dual's scrolling and the place kept across layouts).
    private(set) var sourceMap = SourceMap()
    private var pendingText: String? = nil
    private var pendingTask: Task<Void, Never>? = nil

    /// The editor's history: typing and the coordinator's own changes, recorded by the coordinator
    /// (the text view hands it out as its undo manager; UIKit's own recording is switched off).
    /// Cleared whenever the text is replaced from outside.
    var undo: UndoManager { textView?.ownUndo ?? detachedUndo }
    private let detachedUndo = UndoManager()

    /// Typing that one undo step takes back: where the typed text is now, and what it replaced.
    /// UIKit drops its own typing history whenever the coordinator changes the text (a Return,
    /// a list marker), so the coordinator records typing itself (see `beginKeystroke`).
    final class TypingRun {
        var range: NSRange
        var replaced: NSAttributedString
        init(range: NSRange, replaced: NSAttributedString) {
            self.range = range
            self.replaced = replaced
        }
    }
    private var typingRun: TypingRun?
    /// Keys the editor handles itself, after UIKit has inserted them.
    enum SpecialKey {
        case returnKey, tab, backspace
    }
    /// A keystroke UIKit is inserting: between "should change" and "did change".
    private var keystroke: (range: NSRange, removed: NSAttributedString, lengthBefore: Int, endsWord: Bool,
                            selection: NSRange, special: SpecialKey?)?

    private var batchDepth = 0
    private(set) var isFinishing = false
    private(set) var isLoading = false
    private var directEdits = false
    private var pendingEditedRange: NSRange? = nil
    private var lastChangeWasTyping = false
    /// True when the last change deleted or inserted a paragraph break.
    private var lastChangeSpannedParagraphs = false
    /// True when the last change deleted a paragraph break (a Return only adds one).
    private var lastChangeDeletedBreak = false
    /// Counts storage mutations made by normalization during the current edit.
    private var normalizationEdits = 0
    /// Set while a paragraph is added just after a table (`insertParagraphs`).
    private var allowsTableEdge = false
    /// Typing attributes chosen with an empty selection (e.g. Bold before typing); kept until the cursor moves.
    private var typingOverride: (location: Int, attributes: [NSAttributedString.Key: Any])? = nil

    init(_ parent: PadRichEditorView) {
        self.parent = parent
        self.engine = StyleEngine(style: parent.style)
    }

    private var renderer: MarkdownRenderer { MarkdownRenderer(engine: engine) }
    var storage: NSTextStorage? { textView?.textStorage }
    private var length: Int { storage?.length ?? 0 }
    private var nsString: NSString { (storage?.string ?? "") as NSString }

    // MARK: Loading & publishing

    func load(_ markdown: String) {
        guard let textView, let storage else { return }
        isLoading = true
        let rendered = renderer.renderMapped(markdown)
        storage.setAttributedString(rendered.text)
        sourceMap = rendered.map
        renumberOrderedLists()
        isLoading = false
        undo.removeAllActions()
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.typingAttributes = typingAttributes(at: 0)
        lastKnownText = markdown
        pendingEditedRange = nil
        loadImages()
        refreshState()
    }

    /// New text that did not come from typing here. In Dual, while the cursor is in the other pane,
    /// this pane waits for a pause so fast typing there stays fast.
    func receive(_ markdown: String) {
        guard parent.controller.isDual, textView?.isFirstResponder != true else {
            cancelPendingText()
            reload(markdown)
            return
        }
        guard pendingText != markdown else { return }
        pendingText = markdown
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.flushPendingText()
        }
    }

    func flushPendingText() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let markdown = pendingText else { return }
        pendingText = nil
        if markdown != lastKnownText { reload(markdown) }
    }

    func cancelPendingText() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingText = nil
    }

    /// Replaces the text with a version from elsewhere, keeping the place in the view.
    func reload(_ markdown: String) {
        guard let textView, let storage else { return }
        let selection = textView.selectedRange
        textView.preservingScroll {
            isLoading = true
            let rendered = renderer.renderMapped(markdown)
            storage.setAttributedString(rendered.text)
            sourceMap = rendered.map
            renumberOrderedLists()
            let location = min(selection.location, length)
            textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            isLoading = false

            // The old history describes text that is gone.
            undo.removeAllActions()
            typingRun = nil
            typingOverride = nil
            textView.typingAttributes = typingAttributes(at: location)
            lastKnownText = markdown
            pendingEditedRange = nil
            loadImages()
        }
        refreshState()
        applyBehaviors()
        parent.sync?.resync()
    }

    func restyleAll() {
        guard let textView, let storage else { return }
        directEdits = true
        storage.beginEditing()
        var location = 0
        while location < length {
            let paragraph = paragraphRange(at: location)
            if paragraph.length == 0 { break }
            if isRawTable(paragraph) {
                // Its column stops depend on the text width.
                location = NSMaxRange(paragraph)
                continue
            }
            restyleParagraph(paragraph, block: blockInfo(forParagraph: paragraph))
            location = NSMaxRange(paragraph)
        }
        storage.endEditing()
        directEdits = false
        textView.typingAttributes = typingAttributes(at: textView.selectedRange.location)
        textView.redisplay()
    }

    func markdown(for range: NSRange) -> String {
        guard let storage, range.length > 0 else { return "" }
        return MarkdownSerializer.markdown(from: storage.attributedSubstring(from: range))
    }

    private func publish() {
        guard let storage else { return }
        let (markdown, map) = MarkdownSerializer.serialize(storage)
        sourceMap = map
        if markdown != lastKnownText {
            lastKnownText = markdown
            parent.text = markdown
        }
    }

    // MARK: Paragraph helpers

    func paragraphRange(at location: Int) -> NSRange {
        let clamped = min(max(location, 0), length)
        return nsString.paragraphRange(for: NSRange(location: clamped, length: 0))
    }

    func paragraphRanges(in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var location = range.location
        let end = NSMaxRange(range)
        while true {
            let paragraph = paragraphRange(at: location)
            result.append(paragraph)
            let next = NSMaxRange(paragraph)
            if paragraph.length == 0 || next >= end { break }
            location = next
        }
        return result
    }

    func blockInfo(forParagraph paragraph: NSRange) -> BlockInfo {
        guard paragraph.length > 0, let storage else { return .paragraph }
        if let block = storage.attribute(.mmBlock, at: paragraph.location, effectiveRange: nil) as? BlockInfo {
            return block
        }
        var found: BlockInfo? = nil
        storage.enumerateAttribute(.mmBlock, in: paragraph, options: []) { value, _, stop in
            if let block = value as? BlockInfo {
                found = block
                stop.pointee = true
            }
        }
        return found ?? .paragraph
    }

    func markerLength(ofParagraph paragraph: NSRange) -> Int {
        guard paragraph.length > 0, let storage else { return 0 }
        var range = NSRange(location: 0, length: 0)
        if storage.attribute(.mmMarker, at: paragraph.location, longestEffectiveRange: &range, in: paragraph) != nil {
            return range.length
        }
        return 0
    }

    /// The editable text of a paragraph: no marker, no trailing newline.
    func contentRange(ofParagraph paragraph: NSRange) -> NSRange {
        var range = paragraph
        let marker = markerLength(ofParagraph: paragraph)
        range.location += marker
        range.length -= marker
        if range.length > 0, nsString.character(at: NSMaxRange(range) - 1) == MarkdownSyntax.newlineUTF16 {
            range.length -= 1
        }
        return range
    }

    /// A table: shown read only, saved back as the Markdown it came from.
    func isRawTable(_ paragraph: NSRange) -> Bool {
        guard paragraph.length > 0, let storage, paragraph.location < storage.length else { return false }
        return storage.attribute(.mmRawTable, at: paragraph.location, effectiveRange: nil) != nil
    }

    // MARK: Undo-aware edits

    @discardableResult
    private func replaceText(_ range: NSRange, with attributed: NSAttributedString) -> Bool {
        performEdit(range, replacementString: attributed.string) { $0.replaceCharacters(in: range, with: attributed) }
    }

    private func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        guard range.length > 0 else { return }
        performEdit(range, replacementString: nil) { $0.setAttributes(attributes, range: range) }
    }

    private func addAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        guard range.length > 0 else { return }
        performEdit(range, replacementString: nil) { $0.addAttributes(attributes, range: range) }
    }

    private func removeAttribute(_ key: NSAttributedString.Key, range: NSRange) {
        guard range.length > 0 else { return }
        performEdit(range, replacementString: nil) { $0.removeAttribute(key, range: range) }
    }

    /// One change to the text, recorded for undo by the coordinator itself.
    @discardableResult
    private func performEdit(_ range: NSRange, replacementString: String?, _ change: (NSTextStorage) -> Void) -> Bool {
        guard let storage else { return false }
        if isLoading || directEdits {
            change(storage)
            return true
        }
        guard willChangeText(in: range, replacement: replacementString) else { return false }
        typingRun = nil   // the coordinator's own change ends a run of typing
        let old = storage.attributedSubstring(from: range)
        let before = storage.length
        change(storage)
        registerUndo(restoring: old, in: NSRange(location: range.location, length: range.length + storage.length - before))
        if isFinishing { normalizationEdits += 1 }
        return true
    }

    /// Puts back what a change replaced.
    private func registerUndo(restoring old: NSAttributedString, in range: NSRange) {
        undo.registerUndo(withTarget: self) { coordinator in
            MainActor.assumeIsolated { coordinator.restore(old, in: range) }
        }
    }

    private func restore(_ old: NSAttributedString, in range: NSRange) {
        guard let storage, NSMaxRange(range) <= storage.length else { return }
        let current = storage.attributedSubstring(from: range)
        storage.replaceCharacters(in: range, with: old)
        let restored = NSRange(location: range.location, length: old.length)
        registerUndo(restoring: current, in: restored)
        pendingEditedRange = pendingEditedRange.map { NSUnionRange($0, restored) } ?? restored
        lastChangeSpannedParagraphs = lastChangeSpannedParagraphs
            || old.string.contains("\n") || current.string.contains("\n")
        lastChangeDeletedBreak = lastChangeDeletedBreak || current.string.contains("\n")
        textView?.selectedRange = NSRange(location: min(NSMaxRange(restored), storage.length), length: 0)
    }

    /// UIKit is about to insert a keystroke (or an autocorrection, or a deletion). Its own undo
    /// record would be dropped at the coordinator's next change, so it's switched off for the
    /// keystroke, and `endKeystroke` records it instead, as part of a run of typing.
    func beginKeystroke(replacing range: NSRange, with text: String, special: SpecialKey? = nil) {
        guard let storage, let textView, NSMaxRange(range) <= storage.length else { return }
        keystroke = (range, storage.attributedSubstring(from: range), storage.length,
                     text.last.map { $0.isWhitespace || $0.isPunctuation } ?? false, textView.selectedRange, special)
    }

    /// The cursor is just after a list marker, or at the start of a paragraph.
    func isAtParagraphContentStart(_ location: Int) -> Bool {
        let paragraph = paragraphRange(at: location)
        return paragraph.length > 0 && location == paragraph.location + markerLength(ofParagraph: paragraph)
    }

    /// UIKit inserted the keystroke: record it, extending the run of typing when it follows on.
    /// True when it was a key the editor handles itself, which it has now done.
    @discardableResult
    func endKeystroke() -> Bool {
        guard let stroke = keystroke, let storage, let textView else { return false }
        keystroke = nil
        let inserted = stroke.range.length + storage.length - stroke.lengthBefore
        guard inserted >= 0, stroke.range.location + inserted <= storage.length else { return false }
        if let special = stroke.special {
            // Put back what UIKit did (it isn't recorded), then do what the key does here.
            storage.replaceCharacters(in: NSRange(location: stroke.range.location, length: inserted), with: stroke.removed)
            textView.selectedRange = stroke.selection
            typingRun = nil
            pendingEditedRange = nil
            switch special {
            case .returnKey:
                _ = handleReturn()
            case .tab:
                if !handleTab(forward: true) { typeHere("\t") }
            case .backspace:
                if !handleBackspace() {
                    batch { replaceText(stroke.range, with: NSAttributedString()) }
                    textView.selectedRange = NSRange(location: stroke.range.location, length: 0)
                }
            }
            return true
        }
        if let run = typingRun, extend(run, replacing: stroke.range, removed: stroke.removed, insertedLength: inserted) {
            // Taken back with the rest of the run.
        } else {
            let run = TypingRun(range: NSRange(location: stroke.range.location, length: inserted), replaced: stroke.removed)
            undo.registerUndo(withTarget: self) { coordinator in
                MainActor.assumeIsolated { coordinator.restore(run.replaced, in: run.range) }
            }
            typingRun = run
        }
        // A space or punctuation ends a word: undo takes typing back a word at a time.
        if stroke.endsWord { typingRun = nil }
        return false
    }

    /// Inserts text at the cursor as one undoable step (a Tab outside a list).
    private func typeHere(_ text: String) {
        guard let textView else { return }
        let selection = textView.selectedRange
        batch { replaceText(selection, with: NSAttributedString(string: text, attributes: currentTypingAttributes)) }
        textView.selectedRange = NSRange(location: selection.location + (text as NSString).length, length: 0)
    }

    private func extend(_ run: TypingRun, replacing range: NSRange, removed: NSAttributedString, insertedLength: Int) -> Bool {
        let end = NSMaxRange(run.range)
        if range.length == 0, range.location == end {
            run.range.length += insertedLength          // typing on
            return true
        }
        guard insertedLength == 0, range.length == 1 else { return false }
        if run.range.length > 0, NSMaxRange(range) == end {
            run.range.length -= 1                       // Backspace over what was just typed
            return true
        }
        if run.range.length == 0, NSMaxRange(range) == run.range.location {
            let replaced = NSMutableAttributedString(attributedString: removed)
            replaced.append(run.replaced)               // Backspacing on
            run.replaced = replaced
            run.range.location = range.location
            return true
        }
        return false
    }

    /// The cursor moved somewhere other than the end of the typing: the next keystroke starts anew.
    func selectionMovedForTyping(to selection: NSRange) {
        // UIKit moves the cursor before it reports the keystroke; that move is part of it.
        guard keystroke == nil else { return }
        if let run = typingRun, selection.length > 0 || selection.location != NSMaxRange(run.range) {
            typingRun = nil
        }
    }

    /// After an undo or redo: tidy and save once, when the whole step is back.
    func didUndoOrRedo() {
        guard !isLoading else { return }
        finishEdit()
    }

    /// Groups several edits into one post-edit pass (normalization + publish).
    private func batch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0 && !isFinishing && !isLoading {
            finishEdit()
        }
    }

    // MARK: Text view events (the delegate in PadRichEditorView.swift calls these)

    /// After the text view changed the text (typing, a paste, a deletion).
    func textDidChange() {
        guard !isLoading, !isFinishing, batchDepth == 0 else { return }
        finishEdit()
    }

    /// Before any change: remembers what is being edited, and refuses edits that would break a
    /// protected block (a rule, a table).
    func willChangeText(in affectedCharRange: NSRange, replacement replacementString: String?) -> Bool {
        let newLength = replacementString?.utf16.count ?? affectedCharRange.length
        let edited = NSRange(location: affectedCharRange.location, length: max(newLength, affectedCharRange.length))
        pendingEditedRange = pendingEditedRange.map { NSUnionRange($0, edited) } ?? edited
        if let replacementString {
            lastChangeWasTyping = affectedCharRange.length == 0
                && !replacementString.isEmpty
                && !replacementString.contains("\n")
            if !isFinishing {
                let removed = affectedCharRange.length > 0 && NSMaxRange(affectedCharRange) <= length
                    ? nsString.substring(with: affectedCharRange) : ""
                lastChangeSpannedParagraphs = removed.contains("\n") || replacementString.contains("\n")
                lastChangeDeletedBreak = removed.contains("\n")
            }
        } else {
            lastChangeWasTyping = false
        }
        guard !isLoading, let replacementString else { return true }
        return isAllowedChange(affectedCharRange, replacement: replacementString)
    }

    /// What typing at the cursor should look like now.
    var currentTypingAttributes: [NSAttributedString.Key: Any] {
        effectiveTypingAttributes(at: textView?.selectedRange.location ?? 0)
    }

    func selectionDidChange() {
        guard let textView, !isLoading else { return }
        let selection = textView.selectedRange
        if let override = typingOverride, override.location != selection.location || selection.length > 0 {
            typingOverride = nil
        }
        textView.typingAttributes = effectiveTypingAttributes(at: selection.location)
        refreshState()
        applyBehaviors()
    }

    private func effectiveTypingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        if let override = typingOverride, override.location == location {
            return override.attributes
        }
        return typingAttributes(at: location)
    }

    /// Keeps the cursor and selections out of list markers.
    func adjustedSelection(_ newSelectedCharRange: NSRange) -> NSRange {
        guard !isLoading, length > 0 else { return newSelectedCharRange }
        var range = newSelectedCharRange
        let paragraph = paragraphRange(at: range.location)
        let contentStart = paragraph.location + markerLength(ofParagraph: paragraph)
        let end = NSMaxRange(range)

        if range.location < contentStart {
            let keepsWholeParagraph = range.location == paragraph.location && end >= NSMaxRange(paragraph)
            if range.length == 0 {
                range.location = contentStart
            } else if !keepsWholeParagraph {
                if end <= contentStart {
                    range = NSRange(location: contentStart, length: 0)
                } else {
                    range = NSRange(location: contentStart, length: end - contentStart)
                }
            }
        }
        if range.length > 0 {
            let endParagraph = paragraphRange(at: NSMaxRange(range))
            let endContentStart = endParagraph.location + markerLength(ofParagraph: endParagraph)
            let rangeEnd = NSMaxRange(range)
            if rangeEnd > endParagraph.location, rangeEnd < endContentStart {
                range.length = endContentStart - range.location
            }
        }
        return range
    }

    // MARK: Edit validation

    private func isAllowedChange(_ range: NSRange, replacement: String) -> Bool {
        if allowsTableEdge, range.length == 0 { return true }
        if range.length == 0 {
            let paragraph = paragraphRange(at: range.location)
            if case .horizontalRule = blockInfo(forParagraph: paragraph).kind {
                return replacement.hasPrefix("\n")
            }
            // A table is read only here; a new line can still go in front of it.
            return !isRawTable(paragraph) || range.location == paragraph.location && replacement.hasSuffix("\n")
        }
        for paragraph in paragraphRanges(in: range) {
            let block = blockInfo(forParagraph: paragraph)
            guard block.isProtected else { continue }
            let covers = range.location <= paragraph.location && NSMaxRange(range) >= NSMaxRange(paragraph)
            if !covers { return false }
        }
        return true
    }

    // MARK: Post-edit normalization

    private func finishEdit() {
        guard let textView else { return }
        isFinishing = true
        defer { isFinishing = false }

        let edited = pendingEditedRange ?? textView.selectedRange
        pendingEditedRange = nil
        typingOverride = nil
        let wasTyping = lastChangeWasTyping
        lastChangeWasTyping = false

        let spanned = lastChangeSpannedParagraphs
        let deletedBreak = lastChangeDeletedBreak
        lastChangeSpannedParagraphs = false
        lastChangeDeletedBreak = false
        normalizationEdits = 0

        let start = paragraphRange(at: max(edited.location - 1, 0)).location
        let endLocation = min(NSMaxRange(edited) + 1, length)
        let end = NSMaxRange(paragraphRange(at: endLocation))
        normalize(from: start, to: end)
        renumberOrderedLists()
        if deletedBreak { removeEmptyLeftoverParagraph() }
        if wasTyping && !undo.isUndoing && !undo.isRedoing { applyMarkdownShortcuts() }

        if spanned || normalizationEdits > 0 {
            // Paragraph spacing changed; re-lay the rest of the document.
            let rest = NSRange(location: min(start, length), length: max(length - min(start, length), 0))
            textView.layoutManager.invalidateLayout(forCharacterRange: rest, actualCharacterRange: nil)
        }
        textView.redisplay()
        publish()
        refreshState()
        applyBehaviors()
    }

    /// After a deletion that spanned paragraphs, an empty plain paragraph left at the cursor
    /// is an artifact (it would vanish on save anyway), so close the gap.
    private func removeEmptyLeftoverParagraph() {
        guard let textView else { return }
        let selection = textView.selectedRange
        guard selection.length == 0 else { return }
        let paragraph = paragraphRange(at: selection.location)
        guard paragraph.length == 1, NSMaxRange(paragraph) < length,
              nsString.character(at: paragraph.location) == MarkdownSyntax.newlineUTF16 else { return }
        let block = blockInfo(forParagraph: paragraph)
        switch block.kind {
        case .paragraph, .heading:
            replaceText(paragraph, with: NSAttributedString())
            textView.selectedRange = NSRange(location: paragraph.location, length: 0)
        default:
            return
        }
    }

    private func normalize(from start: Int, to end: Int) {
        var location = start
        var limit = end
        while location < min(limit, length) {
            let paragraph = paragraphRange(at: location)
            if paragraph.length == 0 { break }
            let before = length
            let normalized = normalizeParagraph(paragraph)
            limit += length - before
            if normalized.length == 0 { break }
            location = NSMaxRange(normalized)
        }
    }

    /// Makes one paragraph internally consistent: one block kind, a correct marker, derived visuals.
    private func normalizeParagraph(_ paragraphIn: NSRange) -> NSRange {
        guard let storage, paragraphIn.length > 0 else { return paragraphIn }
        if isRawTable(paragraphIn) { return paragraphIn }
        var paragraph = paragraphIn
        var block = blockInfo(forParagraph: paragraph)
        // Only a table keeps the table-cell kind; text typed beside one (a new line) is a paragraph.
        if block.kind == .tableCell { block = .paragraph }

        var markerRuns: [NSRange] = []
        storage.enumerateAttribute(.mmMarker, in: paragraph, options: []) { value, range, _ in
            if value != nil { markerRuns.append(range) }
        }
        let leadingMarker = markerRuns.first(where: { $0.location == paragraph.location })

        // Remove stray markers that are not at the start.
        for run in markerRuns.reversed() where run.location != paragraph.location {
            replaceText(run, with: NSAttributedString())
            paragraph.length -= run.length
        }

        if block.hasMarker {
            if let leadingMarker {
                if !markerIsValid(leadingMarker, for: block) {
                    let marker = engine.marker(for: block, number: 1)
                    replaceText(leadingMarker, with: marker)
                    paragraph.length += marker.length - leadingMarker.length
                }
            } else {
                let marker = engine.marker(for: block, number: 1)
                replaceText(NSRange(location: paragraph.location, length: 0), with: marker)
                paragraph.length += marker.length
            }
        } else if let leadingMarker {
            replaceText(leadingMarker, with: NSAttributedString())
            paragraph.length -= leadingMarker.length
        }

        paragraph = convertInlineTokens(in: paragraph, block: block)
        normalizeTags(in: paragraph, block: block)
        restyleParagraph(paragraph, block: block)
        return paragraph
    }

    private static let wikiTokenPattern = try! NSRegularExpression(pattern: #"\[\[([^\]|\n]+?)(?:\|([^\]\n]+?))?\]\]"#)
    private static let footnoteTokenPattern = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\](?!:)"#)

    /// Literal `[[Name]]` / `[[Name|Label]]` / `[^id]` typed or pasted into a paragraph become
    /// proper link runs. Returns the paragraph's new range.
    private func convertInlineTokens(in paragraphIn: NSRange, block: BlockInfo) -> NSRange {
        guard let storage, !block.kind.isPlainText else { return paragraphIn }
        var paragraph = paragraphIn
        let content = contentRange(ofParagraph: paragraph)
        guard content.length >= 4 else { return paragraph }
        let text = nsString.substring(with: content)
        let full = NSRange(location: 0, length: (text as NSString).length)

        struct Replacement { let range: NSRange; let run: NSAttributedString }
        var replacements: [Replacement] = []
        for match in Self.wikiTokenPattern.matches(in: text, range: full) {
            let target = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let label = match.range(at: 2).location != NSNotFound
                ? (text as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces) : nil
            guard !target.isEmpty else { continue }
            var style = InlineStyle(attributes: storage.attributes(at: content.location + match.range.location, effectiveRange: nil))
            guard style.wikiLink == nil, style.footnoteRef == nil, !style.code else { continue }
            style.wikiLink = target
            style.link = nil
            let run = NSAttributedString(string: (label?.isEmpty == false ? label! : target),
                                         attributes: engine.attributes(block: block, inline: style))
            replacements.append(Replacement(range: NSRange(location: content.location + match.range.location, length: match.range.length), run: run))
        }
        for match in Self.footnoteTokenPattern.matches(in: text, range: full) {
            let id = (text as NSString).substring(with: match.range(at: 1))
            var style = InlineStyle(attributes: storage.attributes(at: content.location + match.range.location, effectiveRange: nil))
            guard style.wikiLink == nil, style.footnoteRef == nil, !style.code else { continue }
            style.footnoteRef = id
            style.link = nil
            let run = NSAttributedString(string: id, attributes: engine.attributes(block: block, inline: style))
            replacements.append(Replacement(range: NSRange(location: content.location + match.range.location, length: match.range.length), run: run))
        }
        guard !replacements.isEmpty else { return paragraph }
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            replaceText(replacement.range, with: replacement.run)
            paragraph.length += replacement.run.length - replacement.range.length
        }
        return paragraph
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"(?<=^|[\s(,])#[\p{L}\p{N}_/\-]*\p{L}[\p{L}\p{N}_/\-]*"#)

    /// `#tags` are derived from the text: mark exactly the matching runs, nothing else.
    private func normalizeTags(in paragraph: NSRange, block: BlockInfo) {
        guard let storage, !block.kind.isPlainText else { return }
        let content = contentRange(ofParagraph: paragraph)
        guard content.length > 0 else { return }
        let text = nsString.substring(with: content)
        var wanted: [NSRange] = Self.tagPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map { NSRange(location: content.location + $0.range.location, length: $0.range.length) }
        wanted = wanted.filter { range in
            var clean = true
            storage.enumerateAttributes(in: range, options: []) { attrs, _, stop in
                if attrs[.mmWikiLink] != nil || attrs[.mmFootnoteRef] != nil || attrs[.link] != nil || attrs[.attachment] != nil || attrs[.mmCode] != nil {
                    clean = false
                    stop.pointee = true
                }
            }
            return clean
        }
        var existing: [NSRange] = []
        storage.enumerateAttribute(.mmTag, in: content, options: []) { value, range, _ in
            if value != nil { existing.append(range) }
        }
        if existing == wanted { return }
        for range in existing { removeAttribute(.mmTag, range: range) }
        for range in wanted { addAttributes([.mmTag: true], range: range) }
    }

    private func markerIsValid(_ range: NSRange, for block: BlockInfo) -> Bool {
        guard let storage else { return false }
        let text = nsString.substring(with: range)
        switch block.kind {
        case .bullet:
            return text == "\u{2022}\t"
        case .ordered:
            return text.range(of: #"^\d+\.\t$"#, options: .regularExpression) != nil
        case .footnote(let id):
            return text == "\(id)\t"
        case .task:
            guard range.length == 2,
                  nsString.character(at: range.location) == MarkdownSyntax.attachmentUTF16,
                  storage.attribute(.attachment, at: range.location, effectiveRange: nil) is TaskCheckboxAttachment,
                  nsString.character(at: range.location + 1) == 0x09 else { return false }
            return true
        default:
            return false
        }
    }

    /// Recomputes the visual attributes of every run in a paragraph from its semantic attributes.
    private func restyleParagraph(_ paragraph: NSRange, block: BlockInfo) {
        guard paragraph.length > 0, let storage, !isRawTable(paragraph) else { return }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: paragraph, options: []) { attrs, range, _ in
            runs.append((range, attrs))
        }
        for (range, attrs) in runs {
            let expected: [NSAttributedString.Key: Any]
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                let isMarker = attrs[.mmMarker] != nil
                var target = attachment
                if isMarker, let box = attachment as? TaskCheckboxAttachment,
                   case .task(let checked) = block.kind,
                   !engine.checkboxIsCurrent(box, for: block) {
                    target = engine.checkbox(checked: checked)
                }
                expected = engine.attachmentAttributes(block: block, attachment: target, isMarker: isMarker)
            } else if attrs[.mmMarker] != nil {
                expected = engine.markerAttributes(block: block)
            } else {
                expected = engine.attributes(block: block, inline: InlineStyle(attributes: attrs))
            }
            if !AttributeCompare.equal(attrs, expected) {
                setAttributes(expected, range: range)
            }
        }
    }

    private func renumberOrderedLists() {
        var counter = OrderedCounter()
        var location = 0
        while location < length {
            var paragraph = paragraphRange(at: location)
            if paragraph.length == 0 { break }
            let block = blockInfo(forParagraph: paragraph)
            if let number = counter.next(for: block), case .ordered = block.kind {
                let markerLength = markerLength(ofParagraph: paragraph)
                if markerLength > 0 {
                    let markerRange = NSRange(location: paragraph.location, length: markerLength)
                    if nsString.substring(with: markerRange) != "\(number).\t" {
                        let before = length
                        replaceText(markerRange, with: engine.marker(for: block, number: number))
                        paragraph.length += length - before
                    }
                }
            }
            location = NSMaxRange(paragraph)
        }
    }

    /// "# ", "- ", "1. ", "[ ] ", "> " and "``` " typed at the start of a plain paragraph switch its block.
    private func applyMarkdownShortcuts() {
        guard let textView else { return }
        let selection = textView.selectedRange
        guard selection.length == 0 else { return }
        let paragraph = paragraphRange(at: selection.location)
        guard paragraph.length > 0, case .paragraph = blockInfo(forParagraph: paragraph).kind else { return }
        let content = contentRange(ofParagraph: paragraph)
        guard selection.location > content.location, selection.location <= NSMaxRange(content) else { return }
        let typed = nsString.substring(with: NSRange(location: content.location,
                                                      length: selection.location - content.location))

        let newBlock: BlockInfo?
        if let match = typed.wholeMatch(of: #/(#{1,6}) /#) {
            newBlock = BlockInfo(.heading(level: match.1.count))
        } else if typed.wholeMatch(of: #/[-*+] /#) != nil {
            newBlock = BlockInfo(.bullet)
        } else if typed.wholeMatch(of: #/[0-9]+\. /#) != nil {
            newBlock = BlockInfo(.ordered)
        } else if typed.wholeMatch(of: #/([-*+] )?\[[ xX]?\] /#) != nil {
            newBlock = BlockInfo(.task(checked: typed.contains("x") || typed.contains("X")))
        } else if typed == "> " {
            newBlock = BlockInfo(.blockquote)
        } else if typed == "``` " {
            newBlock = BlockInfo(.codeBlock(language: ""))
        } else {
            newBlock = nil
        }
        guard let newBlock else { return }

        batch {
            replaceText(NSRange(location: content.location, length: (typed as NSString).length), with: NSAttributedString())
            let target = paragraphRange(at: content.location)
            setBlock(target, to: newBlock)
        }
        let updated = paragraphRange(at: content.location)
        textView.selectedRange = NSRange(location: updated.location + markerLength(ofParagraph: updated), length: 0)
    }

    // MARK: Typing attributes

    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        let paragraph = paragraphRange(at: location)
        guard paragraph.length > 0, let storage else {
            return engine.attributes(block: .paragraph, inline: InlineStyle())
        }
        var block = blockInfo(forParagraph: paragraph)
        if block.kind == .tableCell { block = .paragraph }
        var inline = InlineStyle()
        let contentStart = paragraph.location + markerLength(ofParagraph: paragraph)
        if location > contentStart, location <= NSMaxRange(paragraph) {
            let previous = storage.attributes(at: location - 1, effectiveRange: nil)
            let previousChar = nsString.character(at: location - 1)
            if previous[.attachment] == nil, previous[.mmMarker] == nil,
               previousChar != MarkdownSyntax.newlineUTF16 {
                inline = InlineStyle(attributes: previous)
                inline.link = nil
                inline.wikiLink = nil
                inline.footnoteRef = nil
                inline.tag = false
            }
        }
        return engine.attributes(block: block, inline: inline)
    }

    // MARK: Key handling

    @discardableResult
    func handleReturn() -> Bool {
        guard let textView else { return false }
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        let content = contentRange(ofParagraph: paragraph)

        switch block.kind {
        case .tableCell:
            // A table is read only: Return makes a new paragraph after it.
            insertParagraphs([emptyParagraph(.paragraph)], after: paragraph, placeCursorIn: 0)
            return true
        case .horizontalRule:
            insertParagraphs([emptyParagraph(.paragraph)], after: paragraph, placeCursorIn: 0)
            return true
        case .bullet, .ordered, .task:
            if content.length == 0 {
                if block.indent > 0 {
                    setIndent(of: paragraph, to: block.indent - 1)
                } else {
                    setBlock(paragraph, to: .paragraph)
                }
                return true
            }
            var newBlock = block
            if case .task = block.kind {
                newBlock = BlockInfo(.task(checked: false), indent: block.indent)
            }
            splitParagraph(at: selection, currentBlock: block, newBlock: newBlock,
                           marker: engine.marker(for: newBlock, number: 1))
            return true
        case .blockquote, .codeBlock, .comment, .frontMatter:
            let atEnd = selection.length == 0 && selection.location == NSMaxRange(content)
            if atEnd, content.length > 0,
               nsString.character(at: NSMaxRange(content) - 1) == MarkdownSyntax.lineSeparatorUTF16 {
                let separator = NSRange(location: NSMaxRange(content) - 1, length: 1)
                batch {
                    replaceText(separator, with: NSAttributedString())
                    splitParagraph(at: NSRange(location: separator.location, length: 0),
                                   currentBlock: block, newBlock: .paragraph, marker: nil)
                }
                return true
            }
            let separator = NSAttributedString(string: MarkdownSyntax.lineSeparatorString,
                                               attributes: engine.attributes(block: block, inline: InlineStyle()))
            batch { replaceText(selection, with: separator) }
            textView.selectedRange = NSRange(location: selection.location + 1, length: 0)
            textView.scrollRangeToVisible(textView.selectedRange)
            return true
        case .heading, .paragraph, .footnote:
            splitParagraph(at: selection, currentBlock: block, newBlock: .paragraph, marker: nil)
            return true
        }
    }

    func handleBackspace() -> Bool {
        guard let textView else { return false }
        let selection = textView.selectedRange
        guard selection.length == 0 else { return false }
        let paragraph = paragraphRange(at: selection.location)
        guard paragraph.length > 0 else { return false }
        let block = blockInfo(forParagraph: paragraph)
        let contentStart = paragraph.location + markerLength(ofParagraph: paragraph)
        guard selection.location == contentStart else { return false }

        switch block.kind {
        case .bullet, .ordered, .task, .blockquote, .codeBlock, .comment, .frontMatter, .footnote:
            setBlock(paragraph, to: .paragraph)
            return true
        case .tableCell:
            return true
        case .horizontalRule:
            batch { replaceText(paragraph, with: NSAttributedString()) }
            return true
        case .heading, .paragraph:
            guard paragraph.location > 0 else { return false }
            let previous = paragraphRange(at: paragraph.location - 1)
            let previousBlock = blockInfo(forParagraph: previous)
            switch previousBlock.kind {
            case .tableCell:
                return true
            case .horizontalRule:
                batch { replaceText(previous, with: NSAttributedString()) }
                return true
            case .blockquote, .codeBlock, .comment, .frontMatter:
                // Join as a new line of the multi-line block instead of merging text.
                let newline = NSRange(location: paragraph.location - 1, length: 1)
                batch {
                    let separator = NSAttributedString(string: MarkdownSyntax.lineSeparatorString,
                                                       attributes: engine.attributes(block: previousBlock, inline: InlineStyle()))
                    replaceText(newline, with: separator)
                    let merged = paragraphRange(at: newline.location)
                    addAttributes([.mmBlock: previousBlock], range: merged)
                    restyleParagraph(merged, block: previousBlock)
                }
                textView.selectedRange = NSRange(location: newline.location + 1, length: 0)
                return true
            default:
                return false
            }
        }
    }

    func handleTab(forward: Bool) -> Bool {
        guard let textView else { return false }
        let selection = textView.selectedRange
        let paragraphs = paragraphRanges(in: selection)
        let blocks = paragraphs.map(blockInfo(forParagraph:))
        if !blocks.isEmpty, blocks.allSatisfy(\.isList) {
            changeIndent(by: forward ? 1 : -1)
            return true
        }
        return !forward
    }

    // MARK: Structural edits

    private func splitParagraph(at selection: NSRange, currentBlock: BlockInfo,
                                newBlock: BlockInfo, marker: NSAttributedString?) {
        guard let textView else { return }
        batch {
            let insertion = NSMutableAttributedString(string: "\n",
                                                      attributes: engine.attributes(block: currentBlock, inline: InlineStyle()))
            if let marker { insertion.append(marker) }
            replaceText(selection, with: insertion)
            let newLocation = selection.location + 1
            let newParagraph = paragraphRange(at: newLocation)
            if newParagraph.length > 0 {
                addAttributes([.mmBlock: newBlock], range: newParagraph)
                restyleParagraph(newParagraph, block: newBlock)
            }
            textView.selectedRange = NSRange(location: newLocation + (marker?.length ?? 0), length: 0)
        }
        textView.typingAttributes = typingAttributes(at: textView.selectedRange.location)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// Changes the block kind of one paragraph. Returns the paragraph's new range.
    @discardableResult
    private func setBlock(_ paragraphIn: NSRange, to newBlock: BlockInfo) -> NSRange {
        guard let textView else { return paragraphIn }
        var paragraph = paragraphIn
        let selection = textView.selectedRange

        if paragraph.length == 0 {
            // Trailing empty paragraph: nothing to store attributes on yet.
            if newBlock.hasMarker {
                let marker = engine.marker(for: newBlock, number: 1)
                batch { replaceText(NSRange(location: paragraph.location, length: 0), with: marker) }
                textView.selectedRange = NSRange(location: paragraph.location + marker.length, length: 0)
            } else {
                let attrs = engine.attributes(block: newBlock, inline: InlineStyle())
                typingOverride = (paragraph.location, attrs)
                textView.typingAttributes = attrs
                refreshState()
            }
            return paragraphRange(at: paragraph.location)
        }

        let oldBlock = blockInfo(forParagraph: paragraph)
        if oldBlock.isProtected { return paragraph }
        let oldMarker = markerLength(ofParagraph: paragraph)
        let cursorOffset = max(selection.location - (paragraph.location + oldMarker), 0)

        batch {
            if oldMarker > 0 {
                replaceText(NSRange(location: paragraph.location, length: oldMarker), with: NSAttributedString())
                paragraph.length -= oldMarker
            }
            if oldBlock.isMultiline && !newBlock.isMultiline {
                // Each line becomes its own paragraph.
                var index = NSMaxRange(paragraph) - 1
                while index >= paragraph.location {
                    if nsString.character(at: index) == MarkdownSyntax.lineSeparatorUTF16 {
                        let attrs = storage?.attributes(at: index, effectiveRange: nil) ?? [:]
                        replaceText(NSRange(location: index, length: 1), with: NSAttributedString(string: "\n", attributes: attrs))
                    }
                    index -= 1
                }
            }
            addAttributes([.mmBlock: newBlock], range: paragraph)
            var newMarker = 0
            if newBlock.hasMarker {
                let marker = engine.marker(for: newBlock, number: 1)
                replaceText(NSRange(location: paragraph.location, length: 0), with: marker)
                paragraph.length += marker.length
                newMarker = marker.length
            }
            for piece in paragraphRanges(in: paragraph) {
                restyleParagraph(piece, block: newBlock)
            }
            let contentLength = paragraph.length - newMarker
            let location = paragraph.location + newMarker + min(cursorOffset, contentLength)
            textView.selectedRange = NSRange(location: min(location, length), length: 0)
        }
        textView.typingAttributes = typingAttributes(at: textView.selectedRange.location)
        return paragraph
    }

    private func setIndent(of paragraph: NSRange, to indent: Int) {
        guard paragraph.length > 0, (0...6).contains(indent) else { return }
        let block = blockInfo(forParagraph: paragraph)
        guard block.isList, block.indent != indent else { return }
        let newBlock = block.with(indent: indent)
        batch {
            addAttributes([.mmBlock: newBlock], range: paragraph)
            restyleParagraph(paragraph, block: newBlock)
        }
    }

    func changeIndent(by delta: Int) {
        guard let textView else { return }
        let selection = textView.selectedRange
        let paragraphs = paragraphRanges(in: selection)
        batch {
            for paragraph in paragraphs {
                let block = blockInfo(forParagraph: paragraph)
                guard block.isList else { continue }
                setIndent(of: paragraph, to: block.indent + delta)
            }
        }
    }

    /// Applies (or, with `toggle`, removes) a block kind to every paragraph in the selection.
    func applyBlock(_ kind: BlockKind, toggle: Bool = true) {
        guard let textView else { return }
        let selection = textView.selectedRange
        let paragraphs = paragraphRanges(in: selection)
        let editable = paragraphs.map { ($0, blockInfo(forParagraph: $0)) }
            .filter { !$0.1.isProtected || $0.0.length == 0 }
        guard !editable.isEmpty else { return }

        let allSame = editable.allSatisfy { $0.1.kind == kind }
        let removing = toggle && allSame
        let lengthBefore = length

        if !removing, kind.isMultiline, editable.count > 1 {
            // Merge the selected paragraphs into one multi-line block.
            batch {
                for index in stride(from: editable.count - 1, through: 1, by: -1) {
                    let paragraph = editable[index].0
                    let previous = editable[index - 1].0
                    guard NSMaxRange(previous) == paragraph.location, paragraph.length > 0 else { continue }
                    let marker = markerLength(ofParagraph: paragraph)
                    if marker > 0 {
                        replaceText(NSRange(location: paragraph.location, length: marker), with: NSAttributedString())
                    }
                    let previousBlock = editable[index - 1].1
                    let separator = NSAttributedString(string: MarkdownSyntax.lineSeparatorString,
                                                       attributes: engine.attributes(block: previousBlock, inline: InlineStyle()))
                    replaceText(NSRange(location: paragraph.location - 1, length: 1), with: separator)
                }
                let merged = paragraphRange(at: editable[0].0.location)
                setBlock(merged, to: BlockInfo(kind))
            }
            return
        }

        batch {
            for (paragraph, block) in editable.reversed() {
                let indent = (block.isList && kind.isList) ? block.indent : 0
                setBlock(paragraph, to: removing ? .paragraph : BlockInfo(kind, indent: indent))
            }
        }
        if editable.count > 1 {
            let first = paragraphRange(at: editable[0].0.location)
            let start = first.location + markerLength(ofParagraph: first)
            let end = min(NSMaxRange(selection) + (length - lengthBefore), length)
            textView.selectedRange = NSRange(location: start, length: max(end - start, 0))
        }
    }

    // MARK: Inline formatting

    func toggleInline(_ key: NSAttributedString.Key) {
        guard let textView, let storage else { return }
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        if block.kind.isPlainText || block.isProtected { return }

        if selection.length == 0 {
            var attrs = textView.typingAttributes
            var inline = InlineStyle(attributes: attrs)
            switch key {
            case .mmBold: inline.bold.toggle()
            case .mmItalic: inline.italic.toggle()
            case .mmStrike: inline.strike.toggle()
            case .mmCode: inline.code.toggle()
            case .mmHighlight: inline.highlight.toggle()
            default: break
            }
            attrs = engine.attributes(block: block, inline: inline)
            typingOverride = (selection.location, attrs)
            textView.typingAttributes = attrs
            refreshState()
            return
        }

        let ranges = contentSubranges(in: selection)
        guard !ranges.isEmpty else { return }
        var allHave = true
        for range in ranges where allHave {
            storage.enumerateAttribute(key, in: range, options: []) { value, _, stop in
                if value == nil {
                    allHave = false
                    stop.pointee = true
                }
            }
        }
        batch {
            for range in ranges {
                if allHave {
                    removeAttribute(key, range: range)
                } else {
                    addAttributes([key: true], range: range)
                }
            }
            for piece in paragraphRanges(in: selection) {
                restyleParagraph(piece, block: blockInfo(forParagraph: piece))
            }
        }
        textView.selectedRange = selection
    }

    /// The link at the selection (or around the cursor), for the link prompt.
    func linkAtSelection() -> (range: NSRange, url: String)? {
        guard let textView, let storage, length > 0 else { return nil }
        let selection = textView.selectedRange
        let probe = selection.length > 0 ? selection.location : max(min(selection.location, length) - 1, 0)
        var range = NSRange()
        guard probe < length,
              let value = storage.attribute(.link, at: probe, longestEffectiveRange: &range, in: paragraphRange(at: probe)),
              storage.attribute(.mmWikiLink, at: probe, effectiveRange: nil) == nil else { return nil }
        let url = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
        if selection.length == 0, !(range.location..<NSMaxRange(range) ~= selection.location) && NSMaxRange(range) != selection.location {
            return nil
        }
        return (range, url)
    }

    /// Sets (or with nil, removes) a link on the selection, or on the whole link around the cursor.
    func applyLink(_ url: String?) {
        guard let textView else { return }
        var selection = textView.selectedRange
        if selection.length == 0, let existing = linkAtSelection() {
            selection = existing.range
        }
        guard selection.length > 0 else { return }
        let ranges = contentSubranges(in: selection)
        batch {
            for range in ranges {
                if let url, !url.isEmpty {
                    addAttributes([.link: URL(string: url) ?? url], range: range)
                } else {
                    removeAttribute(.link, range: range)
                }
            }
            for piece in paragraphRanges(in: selection) {
                restyleParagraph(piece, block: blockInfo(forParagraph: piece))
            }
        }
        textView.selectedRange = selection
    }

    func insertLink(url: String, text: String) {
        guard let textView else { return }
        var trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { return }
        if !trimmedURL.contains(":") { trimmedURL = "https://" + trimmedURL }
        let selection = textView.selectedRange
        if selection.length > 0 || linkAtSelection() != nil {
            applyLink(trimmedURL)
            return
        }
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        if block.kind.isPlainText || block.isProtected { return }
        var inline = InlineStyle(attributes: textView.typingAttributes)
        inline.link = trimmedURL
        inline.wikiLink = nil
        inline.footnoteRef = nil
        let label = text.isEmpty ? trimmedURL : text
        let attrs = engine.attributes(block: block, inline: inline)
        batch { replaceText(selection, with: NSAttributedString(string: label, attributes: attrs)) }
        textView.selectedRange = NSRange(location: selection.location + (label as NSString).length, length: 0)
    }

    /// A `[[Name]]` link to another sheet at the cursor (or with the selection as its label).
    func insertWikiLink(target: String) {
        guard let textView else { return }
        let name = target.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        if block.kind.isPlainText || block.isProtected { return }
        let selected = selection.length > 0 ? nsString.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !selected.contains("\n") else { return }
        var inline = InlineStyle(attributes: selection.length > 0 ? (storage?.attributes(at: selection.location, effectiveRange: nil) ?? [:])
                                                                  : textView.typingAttributes)
        inline.wikiLink = name
        inline.link = nil
        inline.footnoteRef = nil
        let label = selected.isEmpty ? name : selected
        let attrs = engine.attributes(block: block, inline: inline)
        batch { replaceText(selection, with: NSAttributedString(string: label, attributes: attrs)) }
        textView.selectedRange = NSRange(location: selection.location + (label as NSString).length, length: 0)
    }

    func insertImage(alt: String, source: String) {
        guard let textView else { return }
        let trimmedSource = source.trimmingCharacters(in: .whitespaces)
        guard !trimmedSource.isEmpty else { return }
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        if block.isProtected {
            // After a rule or table rather than inside it.
            let image = NSMutableAttributedString(attributedString:
                renderer.imageAttachment(alt: alt, source: trimmedSource, block: .paragraph, paragraphStyle: nil))
            insertParagraphs([MarkdownRenderer.Paragraph(content: image, block: .paragraph, paragraphStyle: nil),
                              emptyParagraph(.paragraph)], after: paragraph, placeCursorIn: 1)
            return
        }
        if block.kind.isPlainText {
            let literal = NSAttributedString(string: "![\(alt)](\(trimmedSource))",
                                             attributes: engine.attributes(block: block, inline: InlineStyle()))
            batch { replaceText(selection, with: literal) }
            return
        }
        let attachment = renderer.imageAttachment(alt: alt, source: trimmedSource, block: block, paragraphStyle: nil)
        batch { replaceText(selection, with: attachment) }
        textView.selectedRange = NSRange(location: selection.location + 1, length: 0)
        loadImages()
    }

    func insertHorizontalRule() {
        guard let textView else { return }
        let anchor = paragraphRange(at: textView.selectedRange.location)
        insertParagraphs([emptyParagraph(.horizontalRule), emptyParagraph(.paragraph)], after: anchor, placeCursorIn: 1)
    }

    /// A small table with placeholder headers. It is filled in from the Raw pane.
    func insertTable(rows: Int, columns: Int) {
        guard let textView else { return }
        let anchor = paragraphRange(at: textView.selectedRange.location)
        var paragraphs = renderer.emptyTableParagraphs(rows: rows, columns: columns)
        paragraphs.append(emptyParagraph(.paragraph))
        insertParagraphs(paragraphs, after: anchor, placeCursorIn: paragraphs.count - 1)
    }

    private func emptyParagraph(_ kind: BlockKind) -> MarkdownRenderer.Paragraph {
        MarkdownRenderer.Paragraph(content: NSMutableAttributedString(), block: BlockInfo(kind), paragraphStyle: nil)
    }

    /// Inserts whole paragraphs after `anchor` (or in place of it when it is an empty plain paragraph).
    private func insertParagraphs(_ paragraphs: [MarkdownRenderer.Paragraph], after anchor: NSRange, placeCursorIn index: Int?) {
        guard let textView, let storage, let last = paragraphs.last else { return }
        let anchorBlock = blockInfo(forParagraph: anchor)
        let anchorStyle = anchor.length > 0 ? storage.attribute(.paragraphStyle, at: anchor.location, effectiveRange: nil) as? NSParagraphStyle : nil
        let content = contentRange(ofParagraph: anchor)
        let anchorHasNewline = NSMaxRange(anchor) > NSMaxRange(content)
        let replaceAnchor = content.length == 0 && !anchorBlock.hasMarker && !anchorBlock.isProtected

        batch {
            let insertion = NSMutableAttributedString()
            let insertAt: Int
            if replaceAnchor {
                insertAt = anchor.location
            } else {
                insertAt = NSMaxRange(content)
                // A table keeps its own newline style, so it goes back exactly as it was.
                let newline = NSMutableAttributedString(attributedString: renderer.newline(for: anchorBlock, paragraphStyle: anchorStyle))
                if isRawTable(anchor), let raw = storage.attribute(.mmRawTable, at: anchor.location, effectiveRange: nil) {
                    newline.addAttribute(.mmRawTable, value: raw, range: NSRange(location: 0, length: newline.length))
                }
                insertion.append(newline)
            }
            insertion.append(renderer.join(paragraphs, trailingNewline: false))
            if !anchorHasNewline {
                insertion.append(renderer.newline(for: last.block, paragraphStyle: last.paragraphStyle))
            }
            // The insertion sits at the end of a table's text, which ordinary edits may not touch.
            allowsTableEdge = isRawTable(anchor)
            replaceText(NSRange(location: insertAt, length: 0), with: insertion)
            allowsTableEdge = false
            if anchorHasNewline {
                // The anchor's old newline now terminates the last inserted paragraph.
                var attrs = engine.attributes(block: last.block, inline: InlineStyle(), paragraphStyle: last.paragraphStyle)
                if let raw = last.content.length > 0 ? last.content.attribute(.mmRawTable, at: 0, effectiveRange: nil) : nil {
                    attrs[.mmRawTable] = raw
                }
                setAttributes(attrs, range: NSRange(location: insertAt + insertion.length, length: 1))
            }
            if let index, index < paragraphs.count {
                var location = replaceAnchor ? insertAt : insertAt + 1
                for i in 0..<index {
                    location += paragraphs[i].content.length + 1
                }
                location += paragraphs[index].content.length
                textView.selectedRange = NSRange(location: min(location, length), length: 0)
            }
        }
        textView.typingAttributes = typingAttributes(at: textView.selectedRange.location)
        textView.scrollRangeToVisible(textView.selectedRange)
        loadImages()
    }

    func toggleTask(at index: Int) {
        let paragraph = paragraphRange(at: index)
        let block = blockInfo(forParagraph: paragraph)
        guard case .task(let checked) = block.kind else { return }
        let newBlock = BlockInfo(.task(checked: !checked), indent: block.indent)
        batch {
            addAttributes([.mmBlock: newBlock], range: paragraph)
            restyleParagraph(paragraph, block: newBlock)
        }
    }

    /// Sub-ranges of a selection that hold ordinary content (no markers, attachments, code, rules or tables).
    private func contentSubranges(in selection: NSRange) -> [NSRange] {
        guard let storage else { return [] }
        var result: [NSRange] = []
        for paragraph in paragraphRanges(in: selection) {
            let block = blockInfo(forParagraph: paragraph)
            if block.kind.isPlainText || block.isProtected { continue }
            let content = contentRange(ofParagraph: paragraph)
            let intersection = NSIntersectionRange(content, selection)
            guard intersection.length > 0 else { continue }
            var cursor = intersection.location
            storage.enumerateAttribute(.attachment, in: intersection, options: []) { value, range, _ in
                if value != nil {
                    if range.location > cursor {
                        result.append(NSRange(location: cursor, length: range.location - cursor))
                    }
                    cursor = NSMaxRange(range)
                }
            }
            if NSMaxRange(intersection) > cursor {
                result.append(NSRange(location: cursor, length: NSMaxRange(intersection) - cursor))
            }
        }
        return result
    }

    // MARK: Footnotes

    private func nextFootnoteID() -> String {
        guard let storage else { return "1" }
        var numbers: [Int] = []
        storage.enumerateAttribute(.mmFootnoteRef, in: NSRange(location: 0, length: length), options: []) { value, _, _ in
            if let id = value as? String, let n = Int(id) { numbers.append(n) }
        }
        storage.enumerateAttribute(.mmBlock, in: NSRange(location: 0, length: length), options: []) { value, _, _ in
            if let block = value as? BlockInfo, case .footnote(let id) = block.kind, let n = Int(id) { numbers.append(n) }
        }
        return String((numbers.max() ?? 0) + 1)
    }

    /// Inserts a `[^n]` reference at the cursor and a matching definition at the end of the document.
    func insertFootnote() {
        guard let textView else { return }
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        if block.kind.isPlainText || block.isProtected { return }
        if case .footnote = block.kind { return }
        let id = nextFootnoteID()
        var style = InlineStyle(attributes: textView.typingAttributes)
        style.footnoteRef = id
        style.link = nil
        style.wikiLink = nil
        let reference = NSAttributedString(string: id, attributes: engine.attributes(block: block, inline: style))
        batch {
            replaceText(NSRange(location: NSMaxRange(selection), length: 0), with: reference)
            let definition = BlockInfo(.footnote(id: id))
            let content = NSMutableAttributedString(attributedString: engine.marker(for: definition, number: 1))
            let anchor = paragraphRange(at: max(length - 1, 0))
            insertParagraphs([MarkdownRenderer.Paragraph(content: content, block: definition, paragraphStyle: nil)],
                             after: anchor, placeCursorIn: 0)
        }
    }

    /// Shows the `[^id]:` definition paragraph.
    @discardableResult
    func jumpToFootnoteDefinition(_ id: String) -> Bool {
        guard let textView else { return false }
        var location = 0
        while location < length {
            let paragraph = paragraphRange(at: location)
            if paragraph.length == 0 { break }
            if case .footnote(let found) = blockInfo(forParagraph: paragraph).kind, found == id {
                textView.reveal(contentRange(ofParagraph: paragraph))
                return true
            }
            location = NSMaxRange(paragraph)
        }
        return false
    }

    /// Shows the first `[^id]` reference in the text.
    @discardableResult
    func jumpToFootnoteReference(_ id: String) -> Bool {
        guard let textView, let storage else { return false }
        var target: NSRange?
        storage.enumerateAttribute(.mmFootnoteRef, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? String == id { target = range; stop.pointee = true }
        }
        guard let target else { return false }
        textView.reveal(target)
        return true
    }

    // MARK: Navigation (dashboard)

    /// Moves the insertion point to the nth heading in the document.
    func jumpToHeading(_ index: Int) {
        guard let textView else { return }
        var seen = 0
        var location = 0
        while location < length {
            let paragraph = paragraphRange(at: location)
            if paragraph.length == 0 { break }
            if case .heading = blockInfo(forParagraph: paragraph).kind {
                if seen == index {
                    textView.reveal(NSRange(location: paragraph.location, length: 0), flash: false)
                    return
                }
                seen += 1
            }
            location = NSMaxRange(paragraph)
        }
    }

    /// Selects the next occurrence of `needle` after the cursor (wrapping).
    func jump(toText needle: String) {
        guard let textView, !needle.isEmpty else { return }
        let ns = nsString
        let start = min(NSMaxRange(textView.selectedRange), ns.length)
        var found = ns.range(of: needle, options: [], range: NSRange(location: start, length: ns.length - start))
        if found.location == NSNotFound { found = ns.range(of: needle) }
        guard found.location != NSNotFound else { return }
        textView.reveal(found, flash: false, select: true)
    }

    // MARK: Hit-testing (taps)

    /// The character under a point in text-container coordinates, if the point is on it.
    func characterHit(atContainerPoint point: CGPoint) -> Int? {
        guard let textView, let storage else { return nil }
        let layoutManager = textView.layoutManager
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textView.textContainer, fractionOfDistanceThroughGlyph: nil)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        // Small things (a footnote number, a checkbox) get a few points of slack around them.
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textView.textContainer)
            .insetBy(dx: -6, dy: -4)
        guard rect.contains(point) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return charIndex < storage.length ? charIndex : nil
    }

    /// What a tap at this point does instead of placing the cursor.
    enum TapAction {
        case toggleTask(Int)
        case footnoteDefinition(String)
        case footnoteReference(String)
        case wikiLink(String)
    }

    func tapAction(atContainerPoint point: CGPoint) -> TapAction? {
        guard let storage, let index = characterHit(atContainerPoint: point) else { return nil }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        if attrs[.attachment] is TaskCheckboxAttachment { return .toggleTask(index) }
        if let id = attrs[.mmFootnoteRef] as? String { return .footnoteDefinition(id) }
        if attrs[.mmMarker] as? Bool == true, case .footnote(let id) = blockInfo(forParagraph: paragraphRange(at: index)).kind {
            return .footnoteReference(id)
        }
        if let target = attrs[.mmWikiLink] as? String { return .wikiLink(target) }
        return nil
    }

    func perform(_ action: TapAction) {
        switch action {
        case .toggleTask(let index): toggleTask(at: index)
        case .footnoteDefinition(let id): jumpToFootnoteDefinition(id)
        case .footnoteReference(let id): jumpToFootnoteReference(id)
        case .wikiLink(let target): parent.controller.openWikiLink?(target)
        }
    }

    /// The web link at a character, for the edit menu's Open Link.
    func webLink(at index: Int) -> URL? {
        guard let storage, index >= 0, index < length,
              storage.attribute(.mmWikiLink, at: index, effectiveRange: nil) == nil else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    // MARK: Pasting

    /// Inserts markdown text at the selection, rendering it in place.
    func insertMarkdown(_ markdown: String) {
        guard let textView else { return }
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")

        if block.isProtected { return }
        if block.kind.isPlainText {
            let joined = normalized.replacingOccurrences(of: "\n", with: MarkdownSyntax.lineSeparatorString)
            let content = NSAttributedString(string: joined, attributes: engine.attributes(block: block, inline: InlineStyle()))
            batch { replaceText(selection, with: content) }
            textView.selectedRange = NSRange(location: selection.location + content.length, length: 0)
            return
        }
        let parsedBlocks = MarkdownParser.parse(normalized).filter {
            if case .blank = $0 { return false }
            return true
        }
        var inlineOnly = false
        if parsedBlocks.count == 1, case .paragraph = parsedBlocks[0] { inlineOnly = true }
        if parsedBlocks.isEmpty || inlineOnly {
            let content = renderer.inlineContent(normalized.replacingOccurrences(of: "\n", with: " "), block: block)
            batch { replaceText(selection, with: content) }
            textView.selectedRange = NSRange(location: selection.location + content.length, length: 0)
            loadImages()
            return
        }

        let rendered = renderer.render(normalized, trailingNewline: false)
        let renderedParagraphs = renderer.paragraphs(for: normalized)
        guard let lastBlock = renderedParagraphs.last?.block else { return }
        let content = contentRange(ofParagraph: paragraph)
        let contentStart = content.location
        let atStart = selection.location <= contentStart
        let atEnd = NSMaxRange(selection) >= NSMaxRange(content)

        let insertion = NSMutableAttributedString()
        var range = selection
        if block.hasMarker && atStart {
            range = NSRange(location: paragraph.location, length: NSMaxRange(selection) - paragraph.location)
            insertion.append(rendered)
            insertion.append(renderer.newline(for: lastBlock, paragraphStyle: renderedParagraphs.last?.paragraphStyle))
        } else {
            if !atStart {
                insertion.append(renderer.newline(for: block))
            }
            insertion.append(rendered)
            if !atEnd || (atEnd && NSMaxRange(paragraph) > NSMaxRange(content)) {
                insertion.append(renderer.newline(for: lastBlock, paragraphStyle: renderedParagraphs.last?.paragraphStyle))
            }
        }
        batch { replaceText(range, with: insertion) }
        textView.selectedRange = NSRange(location: min(range.location + insertion.length, length), length: 0)
        loadImages()
    }

    // MARK: Images

    func loadImages() {
        guard let storage else { return }
        var pendingCachedImages: [(PlatformImage, MarkdownImageAttachment)] = []
        defer { for (image, attachment) in pendingCachedImages { apply(image: image, to: attachment) } }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: []) { value, _, _ in
            guard let attachment = value as? MarkdownImageAttachment, !attachment.loadRequested else { return }
            attachment.loadRequested = true
            let source = attachment.source
            let base = baseURL
            // A known image goes straight in, so reloading while the other pane is edited doesn't flicker.
            if let cached = ImageLoader.shared.cachedImage(for: source, baseURL: base) {
                pendingCachedImages.append((cached, attachment))
                return
            }
            Task { [weak self] in
                guard let image = await ImageLoader.shared.image(for: source, baseURL: base) else { return }
                self?.apply(image: image, to: attachment)
            }
        }
    }

    /// The widest an image may be drawn in the current text column.
    private var maxImageWidth: CGFloat {
        guard let textView else { return 600 }
        let containerWidth = textView.textContainer.size.width
        let viewWidth = textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right
        let base = containerWidth > 50 && containerWidth < 100_000 ? containerWidth : (viewWidth > 50 ? viewWidth : 600)
        let padding = textView.textContainer.lineFragmentPadding
        return min(max(base - 2 * padding - 8, 100), 720)
    }

    /// The image's size scaled down (never up) to fit the column.
    private func fittedSize(of image: PlatformImage) -> CGSize {
        var size = image.size
        let maxWidth = maxImageWidth
        if size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        return CGSize(width: floor(size.width), height: floor(size.height))
    }

    private func apply(image: PlatformImage, to attachment: MarkdownImageAttachment) {
        guard let textView, let storage else { return }
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: fittedSize(of: image))
        attachment.isLoaded = true
        var location: Int? = nil
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: []) { value, range, stop in
            if (value as? MarkdownImageAttachment) === attachment {
                location = range.location
                stop.pointee = true
            }
        }
        if let location {
            let range = NSRange(location: location, length: 1)
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
            textView.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            textView.layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    /// Fits loaded images to a new column width.
    func rescaleImages() {
        guard let textView, let storage, length > 0 else { return }
        var changed = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: []) { value, _, _ in
            guard let attachment = value as? MarkdownImageAttachment, attachment.isLoaded,
                  let image = attachment.image else { return }
            let size = fittedSize(of: image)
            if attachment.bounds.size != size {
                attachment.bounds = CGRect(origin: .zero, size: size)
                changed = true
            }
        }
        if changed {
            textView.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
            textView.redisplay()
        }
    }

    // MARK: Focus and typewriter

    /// Focus dimming and typewriter scrolling for the current selection. In Dual they follow the
    /// cursor, which is only in one pane.
    func applyBehaviors() {
        guard let textView else { return }
        let passive = parent.controller.isDual && !textView.isFirstResponder
        let mode = passive ? FocusMode.off : parent.focus
        let range = FocusMode.range(in: nsString, at: textView.selectedRange.location, mode: mode)
        textView.setFocusRange(range)
        if parent.typewriter, !passive, textView.isFirstResponder {
            textView.typewriterScroll()
        }
    }

    // MARK: Toolbar state

    func refreshState() {
        guard let textView, let storage else { return }
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        let block = blockInfo(forParagraph: paragraph)
        let attrs: [NSAttributedString.Key: Any]
        if selection.length == 0 || length == 0 {
            attrs = textView.typingAttributes
        } else {
            let contentStart = paragraph.location + markerLength(ofParagraph: paragraph)
            let index = min(max(selection.location, contentStart), length - 1)
            attrs = storage.attributes(at: index, effectiveRange: nil)
        }
        let inline = InlineStyle(attributes: attrs)
        let state = FormatState(bold: inline.bold, italic: inline.italic, strike: inline.strike,
                                code: inline.code, highlight: inline.highlight, hasLink: linkAtSelection() != nil,
                                blockKind: block.kind, indent: block.indent,
                                hasSelection: selection.length > 0)
        if parent.controller.formatState != state {
            parent.controller.formatState = state
        }
    }
}
