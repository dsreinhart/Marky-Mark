//
//  RichMarkdownEditorView.swift
//  Marky Mark
//
//  The editable "rendered" view. An NSTextView (TextKit 1, so tables work) that
//  stores semantic attributes and keeps the bound markdown string in sync.
//

import SwiftUI
import AppKit

struct RichMarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    let style: EditorStyle
    let options: EditorOptions
    let baseURL: URL?
    let controller: RichEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = RichTextView(usingTextLayoutManager: false)
        textView.coordinator = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.baseInset = NSSize(width: 24, height: 20)
        textView.textContainerInset = textView.baseInset
        textView.font = context.coordinator.engine.bodyFont
        textView.textColor = .labelColor
        context.coordinator.applyAppearance(to: textView, scrollView: scrollView)
        textView.options = options

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = false

        textView.delegate = context.coordinator
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.baseURL = baseURL
        context.coordinator.load(text)
        controller.coordinator = context.coordinator
        controller.isActive = true
        controller.jumpToHeading = { [weak coordinator = context.coordinator] index in coordinator?.jumpToHeading(index) }
        controller.splitAtCursor = { [weak coordinator = context.coordinator] in coordinator?.splitAtCursor() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.baseURL = baseURL
        if coordinator.engine.style != style {
            coordinator.engine.style = style
            coordinator.restyleAll()
            if let textView = coordinator.textView {
                coordinator.applyAppearance(to: textView, scrollView: scrollView)
            }
        }
        if text != coordinator.lastKnownText {
            coordinator.load(text)
        }
        if let textView = coordinator.textView, textView.options != options {
            textView.options = options
            coordinator.applyBehaviors()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if coordinator.parent.controller.coordinator === coordinator {
            coordinator.parent.controller.coordinator = nil
            coordinator.parent.controller.isActive = false
        }
    }

    // MARK: - Text view subclass

    final class RichTextView: MarkyTextView {
        weak var coordinator: Coordinator?

        override func mouseDown(with event: NSEvent) {
            if let coordinator, coordinator.handleMouseDown(event) { return }
            super.mouseDown(with: event)
        }

        override func paste(_ sender: Any?) {
            if let coordinator, coordinator.pasteFromPasteboard() { return }
            super.paste(sender)
        }

        override func pasteAsPlainText(_ sender: Any?) {
            paste(sender)
        }

        override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
            [.string]
        }

        override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
            guard let coordinator else { return super.writeSelection(to: pboard, types: types) }
            pboard.clearContents()
            pboard.declareTypes([.string], owner: nil)
            pboard.setString(coordinator.markdown(for: selectedRange), forType: .string)
            return true
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichMarkdownEditorView
        let engine: StyleEngine
        weak var textView: RichTextView?
        var baseURL: URL?
        private(set) var lastKnownText = ""

        private var batchDepth = 0
        private var isFinishing = false
        private var isLoading = false
        private var directEdits = false
        private var pendingEditedRange: NSRange? = nil
        private var lastChangeWasTyping = false
        /// True when the last change deleted or inserted a paragraph break.
        private var lastChangeSpannedParagraphs = false
        /// Counts storage mutations made by normalization during the current edit.
        private var normalizationEdits = 0
        /// Typing attributes chosen with an empty selection (e.g. ⌘B before typing); kept until the cursor moves.
        private var typingOverride: (location: Int, attributes: [NSAttributedString.Key: Any])? = nil

        init(_ parent: RichMarkdownEditorView) {
            self.parent = parent
            self.engine = StyleEngine(style: parent.style)
        }

        private var renderer: MarkdownRenderer { MarkdownRenderer(engine: engine) }
        private var storage: NSTextStorage? { textView?.textStorage }
        private var length: Int { storage?.length ?? 0 }
        private var nsString: NSString { (storage?.string ?? "") as NSString }

        // MARK: Loading & publishing

        func load(_ markdown: String) {
            guard let textView, let storage else { return }
            isLoading = true
            storage.setAttributedString(renderer.render(markdown))
            renumberOrderedLists()
            isLoading = false
            textView.undoManager?.removeAllActions()
            textView.selectedRange = NSRange(location: 0, length: 0)
            textView.typingAttributes = typingAttributes(at: 0)
            lastKnownText = markdown
            pendingEditedRange = nil
            loadImages()
            refreshState()
        }

        func restyleAll() {
            guard let textView, let storage else { return }
            directEdits = true
            storage.beginEditing()
            var location = 0
            while location < length {
                let paragraph = paragraphRange(at: location)
                if paragraph.length == 0 { break }
                restyleParagraph(paragraph, block: blockInfo(forParagraph: paragraph))
                location = NSMaxRange(paragraph)
            }
            storage.endEditing()
            directEdits = false
            textView.typingAttributes = typingAttributes(at: textView.selectedRange.location)
            textView.needsDisplay = true
        }

        func markdown(for range: NSRange) -> String {
            guard let storage, range.length > 0 else { return "" }
            return MarkdownSerializer.markdown(from: storage.attributedSubstring(from: range))
        }

        func focus() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }

        /// Applies the theme's editor colors to the views.
        func applyAppearance(to textView: NSTextView, scrollView: NSScrollView) {
            if let background = engine.style.editorBackground {
                textView.drawsBackground = true
                textView.backgroundColor = background
                scrollView.drawsBackground = true
                scrollView.backgroundColor = background
            } else {
                textView.drawsBackground = false
                textView.backgroundColor = .clear
                scrollView.drawsBackground = false
            }
            textView.insertionPointColor = engine.style.textColor
        }

        /// Typewriter scrolling and focus dimming for the current selection.
        func applyBehaviors() {
            guard let textView else { return }
            let options = textView.options
            EditorBehaviors.applyFocus(textView, mode: options.focus, dimColor: engine.style.textColor.withAlphaComponent(0.28))
            if options.typewriter {
                EditorBehaviors.typewriterScroll(textView)
            }
        }

        /// Markdown before and from the cursor's paragraph, for splitting into two sheets.
        func splitAtCursor() -> (String, String)? {
            guard let textView else { return nil }
            let paragraph = paragraphRange(at: textView.selectedRange.location)
            guard paragraph.location > 0, paragraph.location < length else { return nil }
            let before = markdown(for: NSRange(location: 0, length: paragraph.location))
            let after = markdown(for: NSRange(location: paragraph.location, length: length - paragraph.location))
            guard !before.isEmpty, !after.isEmpty else { return nil }
            return (before, after)
        }

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
                        EditorBehaviors.jump(textView, toParagraphAt: paragraph.location)
                        return
                    }
                    seen += 1
                }
                location = NSMaxRange(paragraph)
            }
        }

        private func publish() {
            guard let storage else { return }
            let markdown = MarkdownSerializer.markdown(from: storage)
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

        func tableBlock(forParagraph paragraph: NSRange) -> NSTextTableBlock? {
            guard paragraph.length > 0, let storage else { return nil }
            let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            return style?.textBlocks.first as? NSTextTableBlock
        }

        private func paragraphStyle(forParagraph paragraph: NSRange) -> NSParagraphStyle? {
            guard paragraph.length > 0, let storage else { return nil }
            return storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        }

        private func tableCells(of table: NSTextTable) -> [(row: Int, column: Int, paragraph: NSRange)] {
            var cells: [(Int, Int, NSRange)] = []
            var location = 0
            while location < length {
                let paragraph = paragraphRange(at: location)
                if paragraph.length == 0 { break }
                if let block = tableBlock(forParagraph: paragraph), block.table === table {
                    cells.append((block.startingRow, block.startingColumn, paragraph))
                }
                location = NSMaxRange(paragraph)
            }
            return cells
        }

        // MARK: Undo-aware edits

        @discardableResult
        private func replaceText(_ range: NSRange, with attributed: NSAttributedString) -> Bool {
            guard let textView, let storage else { return false }
            if isLoading || directEdits {
                storage.replaceCharacters(in: range, with: attributed)
                return true
            }
            guard textView.shouldChangeText(in: range, replacementString: attributed.string) else { return false }
            storage.replaceCharacters(in: range, with: attributed)
            if isFinishing { normalizationEdits += 1 }
            textView.didChangeText()
            return true
        }

        private func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
            guard let textView, let storage, range.length > 0 else { return }
            if isLoading || directEdits {
                storage.setAttributes(attributes, range: range)
                return
            }
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.setAttributes(attributes, range: range)
            if isFinishing { normalizationEdits += 1 }
            textView.didChangeText()
        }

        private func addAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
            guard let textView, let storage, range.length > 0 else { return }
            if isLoading || directEdits {
                storage.addAttributes(attributes, range: range)
                return
            }
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.addAttributes(attributes, range: range)
            if isFinishing { normalizationEdits += 1 }
            textView.didChangeText()
        }

        private func removeAttribute(_ key: NSAttributedString.Key, range: NSRange) {
            guard let textView, let storage, range.length > 0 else { return }
            if isLoading || directEdits {
                storage.removeAttribute(key, range: range)
                return
            }
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.removeAttribute(key, range: range)
            if isFinishing { normalizationEdits += 1 }
            textView.didChangeText()
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

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isLoading, !isFinishing, batchDepth == 0 else { return }
            finishEdit()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
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
                }
            } else {
                lastChangeWasTyping = false
            }
            guard !isLoading, let replacementString else { return true }
            return isAllowedChange(affectedCharRange, replacement: replacementString)
        }

        func textView(_ textView: NSTextView,
                      shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            effectiveTypingAttributes(at: textView.selectedRange.location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
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

        func textView(_ textView: NSTextView,
                      willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                      toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
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

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleReturn()
            case #selector(NSResponder.insertTab(_:)):
                return handleTab(forward: true)
            case #selector(NSResponder.insertBacktab(_:)):
                return handleTab(forward: false)
            case #selector(NSResponder.deleteBackward(_:)):
                return handleBackspace()
            default:
                return false
            }
        }

        // MARK: Edit validation

        private func isAllowedChange(_ range: NSRange, replacement: String) -> Bool {
            if range.length == 0 {
                let paragraph = paragraphRange(at: range.location)
                if case .horizontalRule = blockInfo(forParagraph: paragraph).kind {
                    return replacement.hasPrefix("\n")
                }
                return true
            }
            for paragraph in paragraphRanges(in: range) {
                let block = blockInfo(forParagraph: paragraph)
                guard block.isProtected else { continue }
                let covers = range.location <= paragraph.location && NSMaxRange(range) >= NSMaxRange(paragraph)
                let content = contentRange(ofParagraph: paragraph)
                let within = range.location >= content.location && NSMaxRange(range) <= NSMaxRange(content)
                if case .tableCell = block.kind {
                    if !(covers || within) { return false }
                } else if !covers {
                    return false
                }
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
            lastChangeSpannedParagraphs = false
            normalizationEdits = 0

            let start = paragraphRange(at: max(edited.location - 1, 0)).location
            let endLocation = min(NSMaxRange(edited) + 1, length)
            let end = NSMaxRange(paragraphRange(at: endLocation))
            normalize(from: start, to: end)
            renumberOrderedLists()
            if spanned { removeEmptyLeftoverParagraph() }
            if wasTyping { applyMarkdownShortcuts() }

            if spanned || normalizationEdits > 0 {
                // Text blocks and paragraph spacing changed; re-lay the rest of the document.
                let rest = NSRange(location: min(start, length), length: max(length - min(start, length), 0))
                textView.layoutManager?.invalidateLayout(forCharacterRange: rest, actualCharacterRange: nil)
            }
            textView.needsDisplay = true
            publish()
            refreshState()
            if textView.options.focus != .off {
                EditorBehaviors.applyFocus(textView, mode: textView.options.focus,
                                           dimColor: engine.style.textColor.withAlphaComponent(0.28))
            }
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
            var paragraph = paragraphIn
            var block = blockInfo(forParagraph: paragraph)

            let table = tableBlock(forParagraph: paragraph)
            if table != nil, !(block.kind == .tableCell) {
                block = BlockInfo(.tableCell)
            } else if table == nil, block.kind == .tableCell {
                block = .paragraph
            }

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

            if block.isList {
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

            restyleParagraph(paragraph, block: block)
            return paragraph
        }

        private func markerIsValid(_ range: NSRange, for block: BlockInfo) -> Bool {
            guard let storage else { return false }
            let text = nsString.substring(with: range)
            switch block.kind {
            case .bullet:
                return text == "\u{2022}\t"
            case .ordered:
                return text.range(of: #"^\d+\.\t$"#, options: .regularExpression) != nil
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
            guard paragraph.length > 0, let storage else { return }
            let table = tableBlock(forParagraph: paragraph)
            let paragraphStyle = table != nil ? paragraphStyle(forParagraph: paragraph) : nil
            let isHeader = table?.startingRow == 0
            if let table {
                engine.configureTableBlock(table, isHeader: isHeader, columns: table.table.numberOfColumns)
            }

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
                    expected = engine.attachmentAttributes(block: block, attachment: target, isMarker: isMarker,
                                                           paragraphStyle: paragraphStyle)
                } else if attrs[.mmMarker] != nil {
                    expected = engine.markerAttributes(block: block)
                } else {
                    expected = engine.attributes(block: block, inline: InlineStyle(attributes: attrs),
                                                 paragraphStyle: paragraphStyle, isHeaderCell: isHeader)
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
            let block = blockInfo(forParagraph: paragraph)
            let table = tableBlock(forParagraph: paragraph)
            let paragraphStyle = table != nil ? paragraphStyle(forParagraph: paragraph) : nil
            var inline = InlineStyle()
            let contentStart = paragraph.location + markerLength(ofParagraph: paragraph)
            if location > contentStart, location <= NSMaxRange(paragraph) {
                let previous = storage.attributes(at: location - 1, effectiveRange: nil)
                let previousChar = nsString.character(at: location - 1)
                if previous[.attachment] == nil, previous[.mmMarker] == nil,
                   previousChar != MarkdownSyntax.newlineUTF16 {
                    inline = InlineStyle(attributes: previous)
                    inline.link = nil
                }
            }
            return engine.attributes(block: block, inline: inline, paragraphStyle: paragraphStyle,
                                     isHeaderCell: table?.startingRow == 0)
        }

        // MARK: Key handling

        private func handleReturn() -> Bool {
            guard let textView else { return false }
            let selection = textView.selectedRange
            let paragraph = paragraphRange(at: selection.location)
            let block = blockInfo(forParagraph: paragraph)
            let content = contentRange(ofParagraph: paragraph)

            switch block.kind {
            case .tableCell:
                moveToNextRow(from: paragraph)
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
            case .heading, .paragraph:
                splitParagraph(at: selection, currentBlock: block, newBlock: .paragraph, marker: nil)
                return true
            }
        }

        private func handleBackspace() -> Bool {
            guard let textView else { return false }
            let selection = textView.selectedRange
            guard selection.length == 0 else { return false }
            let paragraph = paragraphRange(at: selection.location)
            guard paragraph.length > 0 else { return false }
            let block = blockInfo(forParagraph: paragraph)
            let contentStart = paragraph.location + markerLength(ofParagraph: paragraph)
            guard selection.location == contentStart else { return false }

            switch block.kind {
            case .bullet, .ordered, .task, .blockquote, .codeBlock, .comment, .frontMatter:
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

        private func handleTab(forward: Bool) -> Bool {
            guard let textView else { return false }
            let selection = textView.selectedRange
            let paragraphs = paragraphRanges(in: selection)
            let blocks = paragraphs.map(blockInfo(forParagraph:))
            if !blocks.isEmpty, blocks.allSatisfy(\.isList) {
                changeIndent(by: forward ? 1 : -1)
                return true
            }
            if paragraphs.count == 1, case .tableCell = blocks[0].kind {
                moveToAdjacentCell(from: paragraphs[0], forward: forward)
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
                if newBlock.isList {
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
                if newBlock.isList {
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
            if block.kind.isPlainText { return }
            if case .horizontalRule = block.kind { return }

            if selection.length == 0 {
                var attrs = textView.typingAttributes
                var inline = InlineStyle(attributes: attrs)
                switch key {
                case .mmBold: inline.bold.toggle()
                case .mmItalic: inline.italic.toggle()
                case .mmStrike: inline.strike.toggle()
                case .mmCode: inline.code.toggle()
                default: break
                }
                let table = tableBlock(forParagraph: paragraph)
                attrs = engine.attributes(block: block, inline: inline,
                                          paragraphStyle: table != nil ? paragraphStyle(forParagraph: paragraph) : nil,
                                          isHeaderCell: table?.startingRow == 0)
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

        /// Sets (or with nil, removes) a link on the selection.
        func applyLink(_ url: String?) {
            guard let textView else { return }
            let selection = textView.selectedRange
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
            let trimmedURL = url.trimmingCharacters(in: .whitespaces)
            guard !trimmedURL.isEmpty else { return }
            let selection = textView.selectedRange
            if selection.length > 0 {
                applyLink(trimmedURL)
                return
            }
            let paragraph = paragraphRange(at: selection.location)
            let block = blockInfo(forParagraph: paragraph)
            if block.kind.isPlainText { return }
            if case .horizontalRule = block.kind { return }
            let table = tableBlock(forParagraph: paragraph)
            var inline = InlineStyle(attributes: textView.typingAttributes)
            inline.link = trimmedURL
            let label = text.isEmpty ? trimmedURL : text
            let attrs = engine.attributes(block: block, inline: inline,
                                          paragraphStyle: table != nil ? paragraphStyle(forParagraph: paragraph) : nil,
                                          isHeaderCell: table?.startingRow == 0)
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
            if case .horizontalRule = block.kind { return }
            if block.kind.isPlainText {
                let literal = NSAttributedString(string: "![\(alt)](\(trimmedSource))",
                                                 attributes: engine.attributes(block: block, inline: InlineStyle()))
                batch { replaceText(selection, with: literal) }
                return
            }
            let table = tableBlock(forParagraph: paragraph)
            let attachment = renderer.imageAttachment(alt: alt, source: trimmedSource, block: block,
                                                      paragraphStyle: table != nil ? paragraphStyle(forParagraph: paragraph) : nil)
            batch { replaceText(selection, with: attachment) }
            textView.selectedRange = NSRange(location: selection.location + 1, length: 0)
            loadImages()
        }

        func insertHorizontalRule() {
            guard let textView else { return }
            let anchor = anchorParagraphForBlockInsertion(at: textView.selectedRange.location)
            insertParagraphs([emptyParagraph(.horizontalRule), emptyParagraph(.paragraph)], after: anchor, placeCursorIn: 1)
        }

        func insertTable(rows: Int, columns: Int) {
            guard let textView else { return }
            let anchor = anchorParagraphForBlockInsertion(at: textView.selectedRange.location)
            var paragraphs = renderer.emptyTableParagraphs(rows: rows, columns: columns)
            paragraphs.append(emptyParagraph(.paragraph))
            insertParagraphs(paragraphs, after: anchor, placeCursorIn: 0)
        }

        private func emptyParagraph(_ kind: BlockKind) -> MarkdownRenderer.Paragraph {
            MarkdownRenderer.Paragraph(content: NSMutableAttributedString(), block: BlockInfo(kind), paragraphStyle: nil)
        }

        /// Block insertions inside a table go after the table instead.
        private func anchorParagraphForBlockInsertion(at location: Int) -> NSRange {
            let paragraph = paragraphRange(at: location)
            if let table = tableBlock(forParagraph: paragraph),
               let last = tableCells(of: table.table).last {
                return last.paragraph
            }
            return paragraph
        }

        /// Inserts whole paragraphs after `anchor` (or in place of it when it is an empty plain paragraph).
        private func insertParagraphs(_ paragraphs: [MarkdownRenderer.Paragraph], after anchor: NSRange, placeCursorIn index: Int?) {
            guard let textView, let last = paragraphs.last else { return }
            let anchorBlock = blockInfo(forParagraph: anchor)
            let anchorStyle = paragraphStyle(forParagraph: anchor)
            let content = contentRange(ofParagraph: anchor)
            let anchorHasNewline = NSMaxRange(anchor) > NSMaxRange(content)
            let replaceAnchor = content.length == 0 && !anchorBlock.isList && !anchorBlock.isProtected

            batch {
                let insertion = NSMutableAttributedString()
                let insertAt: Int
                if replaceAnchor {
                    insertAt = anchor.location
                } else {
                    insertAt = NSMaxRange(content)
                    insertion.append(renderer.newline(for: anchorBlock, paragraphStyle: anchorStyle))
                }
                insertion.append(renderer.join(paragraphs, trailingNewline: false))
                if !anchorHasNewline {
                    insertion.append(renderer.newline(for: last.block, paragraphStyle: last.paragraphStyle))
                }
                replaceText(NSRange(location: insertAt, length: 0), with: insertion)
                if anchorHasNewline {
                    // The anchor's old newline now terminates the last inserted paragraph.
                    setAttributes(engine.attributes(block: last.block, inline: InlineStyle(), paragraphStyle: last.paragraphStyle),
                                  range: NSRange(location: insertAt + insertion.length, length: 1))
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

        private func moveToNextRow(from paragraph: NSRange) {
            guard let textView, let block = tableBlock(forParagraph: paragraph) else { return }
            let cells = tableCells(of: block.table)
            if let target = cells.first(where: { $0.row == block.startingRow + 1 && $0.column == block.startingColumn }) {
                textView.selectedRange = NSRange(location: NSMaxRange(contentRange(ofParagraph: target.paragraph)), length: 0)
                textView.scrollRangeToVisible(textView.selectedRange)
            } else if let last = cells.last {
                insertParagraphs([emptyParagraph(.paragraph)], after: last.paragraph, placeCursorIn: 0)
            }
        }

        private func moveToAdjacentCell(from paragraph: NSRange, forward: Bool) {
            guard let textView, let block = tableBlock(forParagraph: paragraph) else { return }
            let cells = tableCells(of: block.table)
            guard let current = cells.firstIndex(where: { $0.paragraph.location == paragraph.location }) else { return }
            let targetIndex = current + (forward ? 1 : -1)
            if cells.indices.contains(targetIndex) {
                let target = cells[targetIndex]
                let content = contentRange(ofParagraph: target.paragraph)
                textView.selectedRange = content
                textView.scrollRangeToVisible(textView.selectedRange)
            } else if forward, let last = cells.last {
                insertParagraphs([emptyParagraph(.paragraph)], after: last.paragraph, placeCursorIn: 0)
            }
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

        /// Sub-ranges of a selection that hold ordinary content (no markers, attachments, code blocks or rules).
        private func contentSubranges(in selection: NSRange) -> [NSRange] {
            guard let storage else { return [] }
            var result: [NSRange] = []
            for paragraph in paragraphRanges(in: selection) {
                let block = blockInfo(forParagraph: paragraph)
                if block.kind.isPlainText { continue }
                if case .horizontalRule = block.kind { continue }
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

        // MARK: Mouse & pasteboard

        func handleMouseDown(_ event: NSEvent) -> Bool {
            guard let textView, let storage,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return false }
            var point = textView.convert(event.locationInWindow, from: nil)
            point.x -= textView.textContainerOrigin.x
            point.y -= textView.textContainerOrigin.y
            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            guard glyphIndex < layoutManager.numberOfGlyphs else { return false }
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
            guard rect.contains(point) else { return false }
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard charIndex < storage.length,
                  storage.attribute(.attachment, at: charIndex, effectiveRange: nil) is TaskCheckboxAttachment else { return false }
            toggleTask(at: charIndex)
            return true
        }

        func pasteFromPasteboard() -> Bool {
            guard let string = NSPasteboard.general.string(forType: .string) else { return false }
            insertMarkdown(string)
            return true
        }

        /// Inserts markdown text at the selection, rendering it in place.
        func insertMarkdown(_ markdown: String) {
            guard let textView else { return }
            let selection = textView.selectedRange
            let paragraph = paragraphRange(at: selection.location)
            let block = blockInfo(forParagraph: paragraph)
            let table = tableBlock(forParagraph: paragraph)
            let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")

            if case .horizontalRule = block.kind { return }

            if case .tableCell = block.kind {
                let flat = normalized.replacingOccurrences(of: "\n", with: " ")
                let content = renderer.inlineContent(flat, block: block, paragraphStyle: paragraphStyle(forParagraph: paragraph),
                                                     isHeaderCell: table?.startingRow == 0)
                batch { replaceText(selection, with: content) }
                textView.selectedRange = NSRange(location: selection.location + content.length, length: 0)
                loadImages()
                return
            }
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
            if block.isList && atStart {
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
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: []) { value, _, _ in
                guard let attachment = value as? MarkdownImageAttachment, !attachment.loadRequested else { return }
                attachment.loadRequested = true
                let source = attachment.source
                let base = baseURL
                Task { [weak self] in
                    guard let image = await ImageLoader.shared.image(for: source, baseURL: base) else { return }
                    self?.apply(image: image, to: attachment)
                }
            }
        }

        private func apply(image: NSImage, to attachment: MarkdownImageAttachment) {
            guard let textView, let storage else { return }
            let containerWidth = textView.textContainer?.size.width ?? 0
            let viewWidth = (textView.enclosingScrollView?.contentSize.width ?? 0) - 2 * textView.textContainerInset.width
            let base = containerWidth > 50 ? containerWidth : (viewWidth > 50 ? viewWidth : 600)
            let padding = textView.textContainer?.lineFragmentPadding ?? 5
            let maxWidth = min(max(base - 2 * padding - 8, 100), 720)

            var size = image.size
            if size.width > maxWidth {
                let scale = maxWidth / size.width
                size = NSSize(width: maxWidth, height: size.height * scale)
            }
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
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
                textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
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
                                    code: inline.code, hasLink: inline.link != nil,
                                    blockKind: block.kind, indent: block.indent,
                                    hasSelection: selection.length > 0)
            if parent.controller.state != state {
                parent.controller.state = state
            }
        }
    }
}
