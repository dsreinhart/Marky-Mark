//
//  PadRichEditorView.swift
//  Markwright iPad
//
//  The formatted editor on iPad (the Formatted layout, and the right pane of Dual): a UITextView
//  on TextKit 1 whose editing logic is in PadRichCoordinator.swift. This file holds what UIKit
//  needs: the text view, its delegate, drawing for quotes, code, rules and tables (iPadOS has no
//  text blocks), focus dimming, taps on checkboxes, footnotes and wiki links, and the pasteboard.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PadRichEditorView: UIViewRepresentable {
    @Binding var text: String
    let style: EditorStyle
    let baseURL: URL?
    var typewriter = false
    var focus: FocusMode = .off
    let controller: PadEditorController
    var sync: PadDualSync? = nil

    func makeCoordinator() -> PadRichCoordinator {
        PadRichCoordinator(self)
    }

    func makeUIView(context: Context) -> PadRichTextView {
        let coordinator = context.coordinator
        let textView = PadRichTextView.make()
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.font = coordinator.engine.bodyFont
        textView.textColor = style.textColor
        textView.allowsEditingTextAttributes = false
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.layoutManager.allowsNonContiguousLayout = false
        textView.maxTextWidth = style.maxWidth
        textView.typewriter = typewriter
        textView.richLayoutManager?.engine = coordinator.engine
        apply(appearanceTo: textView)

        coordinator.textView = textView
        coordinator.baseURL = baseURL
        coordinator.load(text)
        textView.installInteractions()
        textView.setUpUndo()
        controller.rich = coordinator
        sync?.rich = coordinator
        textView.onContentHeightChange = { [weak sync] in sync?.contentHeightChanged() }
        return textView
    }

    func updateUIView(_ textView: PadRichTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.baseURL = baseURL
        if coordinator.engine.style != style {
            coordinator.engine.style = style
            textView.maxTextWidth = style.maxWidth
            // Re-rendered rather than restyled: a table's column stops depend on the style too.
            coordinator.reload(coordinator.lastKnownText)
            apply(appearanceTo: textView)
        }
        if textView.typewriter != typewriter {
            textView.typewriter = typewriter
            textView.setNeedsLayout()
        }
        if text != coordinator.lastKnownText {
            coordinator.receive(text)
        } else {
            coordinator.cancelPendingText()
        }
        if controller.rich !== coordinator {
            controller.rich = coordinator
        }
        if sync?.rich !== coordinator { sync?.rich = coordinator }
        coordinator.applyBehaviors()
    }

    static func dismantleUIView(_ textView: PadRichTextView, coordinator: PadRichCoordinator) {
        coordinator.cancelPendingText()
        let controller = coordinator.parent.controller
        if controller.rich === coordinator {
            controller.paneWillDisappear(.formatted)
            controller.rich = nil
        }
    }

    private func apply(appearanceTo textView: PadRichTextView) {
        textView.backgroundColor = style.editorBackground ?? .systemBackground
        textView.tintColor = style.editorBackground == nil ? nil : style.textColor
    }
}

// MARK: - Text view

final class PadRichTextView: UITextView {
    weak var coordinator: PadRichCoordinator?
    /// Set while the delegate moves the selection off a list marker.
    var isAdjustingSelection = false
    /// Called after layout when the content height changed (images arriving, rotation).
    var onContentHeightChange: (() -> Void)?
    private var lastContentHeight: CGFloat = 0

    /// A text view on TextKit 1 with the layout manager that draws quotes, code, rules and tables.
    static func make() -> PadRichTextView {
        let storage = NSTextStorage()
        let layoutManager = PadRichLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        return PadRichTextView(frame: .zero, textContainer: container)
    }

    var richLayoutManager: PadRichLayoutManager? { layoutManager as? PadRichLayoutManager }

    // MARK: Undo

    /// The editor's own history. UIKit's text undo manager would record each keystroke and lose
    /// them whenever the editor itself changes the text (a Return, a list marker), so its recording
    /// is switched off and the coordinator records everything here instead.
    let ownUndo = UndoManager()
    override var undoManager: UndoManager? { ownUndo }
    private var undoObservers: [NSObjectProtocol] = []

    /// Turns UIKit's own recording off, and tidies once after each undo or redo step.
    func setUpUndo() {
        if let system = super.undoManager, system !== ownUndo, system.isUndoRegistrationEnabled {
            system.disableUndoRegistration()
        }
        guard undoObservers.isEmpty else { return }
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: ownUndo, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let coordinator = self.coordinator else { return }
                    self.ownUndo.disableUndoRegistration()
                    coordinator.didUndoOrRedo()
                    self.ownUndo.enableUndoRegistration()
                    self.typingAttributes = coordinator.currentTypingAttributes
                }
            })
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // UIKit can hand the view a new text undo manager when it takes the keyboard.
        if accepted { setUpUndo() }
        return accepted
    }

    func redisplay() {
        setNeedsDisplay()
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
    }

    /// Runs `body` (which replaces the text) and puts the scroll position back.
    func preservingScroll(_ body: () -> Void) {
        let offset = contentOffset
        body()
        layoutIfNeeded()
        let maxY = max(contentSize.height + adjustedContentInset.bottom - bounds.height, -adjustedContentInset.top)
        setContentOffset(CGPoint(x: offset.x, y: min(offset.y, maxY)), animated: false)
    }

    // MARK: Column

    /// The text column's maximum width; wider views get equal side margins.
    var maxTextWidth: CGFloat = 0 {
        didSet { if maxTextWidth != oldValue { setNeedsLayout() } }
    }
    /// Room below the text so the line being typed can sit in the middle of the view.
    var typewriter = false
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        var inset = UIEdgeInsets(top: 20, left: 20, bottom: 60, right: 20)
        if maxTextWidth > 0 {
            let side = max(20, floor((bounds.width - maxTextWidth) / 2))
            inset.left = side
            inset.right = side
        }
        if typewriter {
            inset.bottom = max(60, floor(bounds.height / 2))
        }
        if textContainerInset != inset {
            textContainerInset = inset
        }
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 1 {
            lastWidth = bounds.width
            coordinator?.rescaleImages()
        }
        if abs(contentSize.height - lastContentHeight) > 0.5 {
            lastContentHeight = contentSize.height
            onContentHeightChange?()
        }
    }

    // MARK: Focus and typewriter

    /// Dims everything outside `range` (nil dims nothing).
    func setFocusRange(_ range: NSRange?) {
        guard let manager = richLayoutManager, manager.focusRange != range else { return }
        manager.focusRange = range
        redisplay()
    }

    /// Scrolls so the line with the insertion point sits in the middle of the view.
    func typewriterScroll() {
        guard selectedRange.length == 0, let position = selectedTextRange?.end else { return }
        let caret = caretRect(for: position)
        guard caret.height.isFinite, caret.height > 0 else { return }
        let target = caret.midY - bounds.height / 2
        let maxOffset = max(contentSize.height + adjustedContentInset.bottom - bounds.height, -adjustedContentInset.top)
        let y = min(max(target, -adjustedContentInset.top), maxOffset)
        if abs(y - contentOffset.y) > 2 {
            setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: true)
        }
    }

    /// Shows a place: puts the cursor there (or selects it), scrolls it a little below the top,
    /// and tints it briefly so the eye finds it.
    func reveal(_ range: NSRange, flash: Bool = true, select: Bool = false) {
        let length = textStorage.length
        let location = min(range.location, length)
        let target = NSRange(location: location, length: min(range.length, length - location))
        _ = becomeFirstResponder()
        selectedRange = select ? target : NSRange(location: location, length: 0)
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: max(target.length, 1)),
                                              actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect = rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        let maxOffset = max(contentSize.height + adjustedContentInset.bottom - bounds.height, -adjustedContentInset.top)
        let y = min(max(rect.minY - bounds.height * 0.2, -adjustedContentInset.top), maxOffset)
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: true)
        if flash { self.flash(rect.insetBy(dx: -4, dy: -2)) }
    }

    private func flash(_ rect: CGRect) {
        let layer = CALayer()
        layer.frame = rect
        layer.cornerRadius = 4
        layer.backgroundColor = tintColor.withAlphaComponent(0.25).cgColor
        self.layer.addSublayer(layer)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.8
        fade.duration = 0.6
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { layer.removeFromSuperlayer() }
    }

    // MARK: Taps

    private lazy var actionTap = UITapGestureRecognizer(target: self, action: #selector(tappedAction(_:)))

    func installInteractions() {
        actionTap.delegate = self
        addGestureRecognizer(actionTap)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PadRichTextView, _: UITraitCollection) in
            view.redisplay()
        }
    }

    /// A point in this view, in the text container's coordinates.
    func containerPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
    }

    private func tapAction(at point: CGPoint) -> PadRichCoordinator.TapAction? {
        coordinator?.tapAction(atContainerPoint: containerPoint(point))
    }

    /// A tap on a checkbox, footnote or wiki link acts on it instead of placing the cursor.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === actionTap {
            return tapAction(at: gestureRecognizer.location(in: self)) != nil
        }
        if gestureRecognizer is UITapGestureRecognizer, tapAction(at: gestureRecognizer.location(in: self)) != nil {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func tappedAction(_ recognizer: UITapGestureRecognizer) {
        guard let coordinator, let action = tapAction(at: recognizer.location(in: self)) else { return }
        coordinator.perform(action)
    }

    // MARK: Keyboard shortcuts

    override func toggleBoldface(_ sender: Any?) { coordinator?.toggleInline(.mmBold) }
    override func toggleItalics(_ sender: Any?) { coordinator?.toggleInline(.mmItalic) }
    override func toggleUnderline(_ sender: Any?) {}

    /// Shift-Tab outdents a list item; UIKit sends it no text.
    override var keyCommands: [UIKeyCommand]? {
        let backtab = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent))
        backtab.wantsPriorityOverSystemBehavior = true
        return [backtab]
    }

    @objc private func outdent() { _ = coordinator?.handleTab(forward: false) }

    // MARK: Pasteboard

    /// Copies the selection as Markdown, as the Mac does.
    override func copy(_ sender: Any?) {
        guard let coordinator, selectedRange.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = coordinator.markdown(for: selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0, isEditable else { return super.cut(sender) }
        copy(sender)
        deleteBackward()
    }

    /// Text is read as Markdown; a picture is saved like one picked with the image button.
    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        guard let coordinator else { return super.paste(sender) }
        if !pasteboard.hasStrings, let picture = Self.imageData(on: pasteboard) {
            coordinator.parent.controller.pasteImage?(picture.data, picture.type)
            return
        }
        if let string = pasteboard.string {
            coordinator.insertMarkdown(string)
            return
        }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return isEditable && (UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages)
        }
        if action == #selector(toggleBoldface(_:)) || action == #selector(toggleItalics(_:)) {
            return isEditable
        }
        if action == #selector(toggleUnderline(_:)) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    /// A copied picture, as PNG, JPEG or HEIC.
    static func imageData(on pasteboard: UIPasteboard) -> (data: Data, type: UTType)? {
        for type in [UTType.png, .jpeg, .heic] {
            if let data = pasteboard.data(forPasteboardType: type.identifier) { return (data, type) }
        }
        if let image = pasteboard.image, let png = image.pngData() { return (png, .png) }
        return nil
    }
}

extension PadRichTextView: UIGestureRecognizerDelegate {}

// MARK: - Text view events

extension PadRichCoordinator: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isLoading, !undo.isUndoing, !undo.isRedoing else { return true }
        // Return, Tab and Backspace at the start of a paragraph do what they do on the Mac (continue a
        // list, leave it, indent…). UIKit inserts the key first and the editor then puts the text back
        // and does that, in "did change": changing the text from here, before UIKit has, makes UIKit
        // drop its undo history (found in Do Re:Me, 2026-11-17).
        var special: SpecialKey?
        if textView.markedTextRange == nil {
            let selection = textView.selectedRange
            if text == "\n", range == selection {
                special = .returnKey
            } else if text == "\t", range == selection {
                special = .tab
            } else if text.isEmpty, selection.length == 0, range.length == 1, NSMaxRange(range) == selection.location,
                      isAtParagraphContentStart(selection.location) {
                special = .backspace
            }
        }
        if special == nil {
            guard willChangeText(in: range, replacement: text) else { return false }
        }
        beginKeystroke(replacing: range, with: text, special: special)
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        if endKeystroke() {
            textView.typingAttributes = currentTypingAttributes
            return
        }
        // Japanese and Chinese input, and dictation, mark text until it's chosen; tidy after that.
        guard textView.markedTextRange == nil, !undo.isUndoing, !undo.isRedoing else { return }
        textDidChange()
        textView.typingAttributes = currentTypingAttributes
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let rich = textView as? PadRichTextView, !rich.isAdjustingSelection,
              textView.markedTextRange == nil else { return }
        let adjusted = adjustedSelection(textView.selectedRange)
        if adjusted != textView.selectedRange {
            rich.isAdjustingSelection = true
            textView.selectedRange = adjusted
            rich.isAdjustingSelection = false
        }
        selectionMovedForTyping(to: textView.selectedRange)
        selectionDidChange()
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        // Text typed in the other pane may still be on its way here.
        flushPendingText()
        return true
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        parent.controller.paneDidTakeFocus(.formatted)
        applyBehaviors()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        applyBehaviors()
    }

    /// Open Link in the edit menu when the cursor or selection is on a web link.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let probe = range.length > 0 ? range.location : max(range.location - 1, 0)
        guard let url = webLink(at: probe) ?? webLink(at: range.location) else { return nil }
        let open = UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { _ in
            UIApplication.shared.open(url)
        }
        return UIMenu(children: [open] + suggestedActions)
    }

    // Scrolling, for Dual.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        parent.sync?.paneDidScroll(.formatted)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        parent.sync?.paneWillBeginDragging(.formatted)
    }
}

// MARK: - Drawing

/// iPadOS has no text blocks, so the layout manager draws what they draw on the Mac: a bar beside a
/// quote or comment, a panel behind code and front matter, a rule's line, a line under large headings
/// and a frame around a table. It also dims the text outside the focus range.
final class PadRichLayoutManager: NSLayoutManager {
    weak var engine: StyleEngine?
    /// Text outside this range is dimmed (Focus); nil dims nothing.
    var focusRange: NSRange?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let focusRange, let context = UIGraphicsGetCurrentContext() else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let focusGlyphs = glyphRange(forCharacterRange: focusRange, actualCharacterRange: nil)
        let start = glyphsToShow.location, end = NSMaxRange(glyphsToShow)
        let inStart = min(max(focusGlyphs.location, start), end)
        let inEnd = min(max(NSMaxRange(focusGlyphs), inStart), end)
        func draw(_ from: Int, _ to: Int, dimmed: Bool) {
            guard to > from else { return }
            if dimmed {
                context.saveGState()
                context.setAlpha(0.28)
            }
            super.drawGlyphs(forGlyphRange: NSRange(location: from, length: to - from), at: origin)
            if dimmed { context.restoreGState() }
        }
        draw(start, inStart, dimmed: true)
        draw(inStart, inEnd, dimmed: false)
        draw(inEnd, end, dimmed: true)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, let engine,
              let context = UIGraphicsGetCurrentContext(), storage.length > 0 else { return }
        let style = engine.style
        let text = storage.string as NSString
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var location = text.paragraphRange(for: NSRange(location: min(shown.location, storage.length - 1), length: 0)).location
        let padding = container.lineFragmentPadding
        let left = origin.x + padding
        let right = origin.x + container.size.width - padding

        while location < min(NSMaxRange(shown), storage.length) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraph) }
            guard paragraph.length > 0,
                  let block = storage.attribute(.mmBlock, at: paragraph.location, effectiveRange: nil) as? BlockInfo else { continue }
            let kind = block.kind
            switch kind {
            case .blockquote, .codeBlock, .horizontalRule, .tableCell, .comment, .frontMatter:
                break
            case .heading(let level) where style.headingDividers && level <= 2:
                break
            default:
                continue
            }
            // The paragraph's lines (without the spacing after them).
            var lines = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)) { _, used, _, _, _ in
                lines = lines.union(used)
            }
            guard !lines.isNull else { continue }
            lines = lines.offsetBy(dx: origin.x, dy: origin.y)
            switch kind {
            case .blockquote:
                let bar = CGRect(x: left + 1, y: lines.minY + 1, width: 3, height: max(lines.height - 2, 4))
                fill(UIBezierPath(roundedRect: bar, cornerRadius: 1.5), style.blockquoteBarColor.withAlphaComponent(0.7))
            case .comment:
                let bar = CGRect(x: left + 1, y: lines.minY + 1, width: 2, height: max(lines.height - 2, 4))
                fill(UIBezierPath(rect: bar), .tertiaryLabel)
            case .codeBlock, .frontMatter:
                let inset = StyleEngine.codeInset
                let panel = CGRect(x: left, y: lines.minY - inset / 2 - 2, width: right - left, height: lines.height + inset + 4)
                let path = UIBezierPath(roundedRect: panel, cornerRadius: 6)
                if case .codeBlock = kind {
                    fill(path, style.codeBlockBackground)
                } else {
                    fill(path, PlatformColor.mmQuaternaryLabel.withAlphaComponent(0.12))
                }
                PlatformColor.separator.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            case .horizontalRule:
                context.setFillColor(PlatformColor.separator.cgColor)
                context.fill(CGRect(x: left, y: lines.midY.rounded() - 0.5, width: right - left, height: 1))
            case .heading:
                context.setFillColor(PlatformColor.separator.cgColor)
                context.fill(CGRect(x: left, y: (lines.maxY + StyleEngine.headingRuleGap / 2).rounded(), width: right - left, height: 1))
            case .tableCell:
                drawTable(paragraph, lines: lines, left: left, right: right, style: style, origin: origin, context: context)
            default:
                break
            }
        }
    }

    /// A grid behind a read-only table: a frame, the header row tinted, a line under each row.
    private func drawTable(_ paragraph: NSRange, lines: CGRect, left: CGFloat, right: CGFloat,
                           style: EditorStyle, origin: CGPoint, context: CGContext) {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        // One rect per row: rows are separated by line separators inside the paragraph.
        var rows: [CGRect] = []
        var rowStart = paragraph.location
        let end = NSMaxRange(paragraph)
        var index = paragraph.location
        while index <= end {
            let atBreak = index == end || text.character(at: index) == MarkdownSyntax.lineSeparatorUTF16
                || text.character(at: index) == MarkdownSyntax.newlineUTF16
            if atBreak {
                let range = NSRange(location: rowStart, length: max(index - rowStart, 1))
                var rect = CGRect.null
                enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { full, _, _, _, _ in
                    rect = rect.union(full)
                }
                if !rect.isNull { rows.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
                rowStart = index + 1
                if index < end, text.character(at: index) == MarkdownSyntax.newlineUTF16 { break }
            }
            index += 1
        }
        guard let first = rows.first else { return }
        // The last row ends where its text does, not after the space below the table.
        let frame = CGRect(x: left - 2, y: first.minY - 4, width: right - left + 4, height: lines.maxY - first.minY + 8)
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 6)
        context.saveGState()
        path.addClip()
        let header = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: first.maxY - frame.minY)
        style.tableHeaderBackground.setFill()
        UIRectFill(header)
        PlatformColor.separator.setFill()
        for row in rows.dropLast() {
            UIRectFill(CGRect(x: frame.minX, y: row.maxY.rounded() - 0.5, width: frame.width, height: 0.5))
        }
        context.restoreGState()
        PlatformColor.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func fill(_ path: UIBezierPath, _ color: UIColor) {
        color.setFill()
        path.fill()
    }
}
