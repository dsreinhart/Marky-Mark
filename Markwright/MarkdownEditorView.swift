//
//  MarkdownEditorView.swift
//  Markwright
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI
import AppKit

/// A syntax-highlighted Markdown editor backed by NSTextView.
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var style: EditorStyle? = nil
    var options = EditorOptions()
    var controller: RichEditorController? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = MarkwrightTextView(usingTextLayoutManager: false)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: context.coordinator.fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.baseInset = NSSize(width: 16, height: 14)
        textView.textContainerInset = textView.baseInset
        textView.options = options
        textView.layoutManager?.allowsNonContiguousLayout = false

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        textView.wikiCompletions = { partial in LibraryModel.shared.sheetNames(matching: partial) }
        textView.handlesFootnoteClicks = true

        // In this order: laid out outside a scroll view, the text pushes the view's origin
        // up by a line for every line of text, and it stays displaced.
        scrollView.documentView = textView
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.applyAppearance()
        context.coordinator.applySyntaxHighlighting()
        controller?.editorsWillChange()
        if controller?.pendingPosition != nil { scrollView.alphaValue = 0 }
        controller?.rawCoordinator = context.coordinator
        controller?.rawTextView = textView
        textView.onTakeFocus = { [weak controller] view in controller?.paneDidTakeFocus(view) }
        controller?.refreshActive()
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingText()
        if let controller = coordinator.parent.controller, controller.rawTextView === nsView.documentView {
            controller.editorsWillChange()
            controller.rawTextView = nil
            controller.rawCoordinator = nil
            controller.refreshActive()
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkwrightTextView else { return }
        context.coordinator.parent = self
        if context.coordinator.styleVersion != style?.version {
            context.coordinator.styleVersion = style?.version
            context.coordinator.applyAppearance()
            context.coordinator.applySyntaxHighlighting()
        }
        if textView.options != options {
            textView.options = options
            context.coordinator.applyBehaviors()
        }
        if textView.string != text {
            context.coordinator.receive(text)
        } else {
            context.coordinator.cancelPendingText()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        var styleVersion: Int? = nil
        /// Separate from the window's, so the two panes of dual mode keep separate histories.
        private let undo = UndoManager()
        private var pendingText: String? = nil
        private var pendingTask: Task<Void, Never>? = nil

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        // MARK: Text from elsewhere

        /// New text that did not come from typing here. In dual mode, the pane without the cursor
        /// waits for a pause so that fast typing in the other pane stays fast.
        func receive(_ text: String) {
            guard let controller = parent.controller, controller.isDual,
                  textView?.window?.firstResponder !== textView else {
                apply(text)
                return
            }
            guard pendingText != text else { return }
            pendingText = text
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
            guard let text = pendingText else { return }
            pendingText = nil
            if textView?.string != text { apply(text) }
        }

        func cancelPendingText() {
            pendingTask?.cancel()
            pendingTask = nil
            pendingText = nil
        }

        private func apply(_ text: String) {
            guard let textView else { return }
            let clip = scrollView?.contentView
            let origin = clip?.bounds.origin
            let length = (text as NSString).length
            let selection = textView.selectedRange
            let location = min(selection.location, length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            // The old history describes text that is gone.
            undo.removeAllActions()
            applySyntaxHighlighting()
            if let clip, let origin, let scrollView {
                clip.scroll(to: origin)
                scrollView.reflectScrolledClipView(clip)
            }
            parent.controller?.paneSync.resync()
        }

        var fontSize: CGFloat { parent.style?.bodySize ?? 14 }
        private var baseColor: NSColor { parent.style?.textColor ?? .labelColor }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
            applySyntaxHighlighting()
            applyBehaviors()
            (textView as? MarkwrightTextView)?.showWikiCompletionsIfNeeded()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, let target = WikiLink.target(from: url) else { return false }
            WikiLinkResolver.open(target, near: parent.controller?.documentURL)
            return true
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let editor = textView as? MarkwrightTextView, editor.wikiPartialRange() != nil else { return words }
            let partial = (textView.string as NSString).substring(with: charRange)
            return editor.wikiCompletions?(partial) ?? []
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            applyBehaviors()
        }

        func applyAppearance() {
            guard let textView, let scrollView else { return }
            if let background = parent.style?.editorBackground {
                textView.drawsBackground = true
                textView.backgroundColor = background
                scrollView.drawsBackground = true
                scrollView.backgroundColor = background
            } else {
                textView.drawsBackground = false
                textView.backgroundColor = .clear
                scrollView.drawsBackground = false
            }
            textView.insertionPointColor = baseColor
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        func applyBehaviors() {
            guard let textView = textView as? MarkwrightTextView else { return }
            // In dual mode these follow the cursor, which is only in one pane.
            let isPassive = parent.controller?.isDual == true && textView.window?.firstResponder !== textView
            EditorBehaviors.applyFocus(textView, mode: isPassive ? .off : textView.options.focus, dimColor: baseColor.withAlphaComponent(0.28))
            if textView.options.typewriter, !isPassive {
                EditorBehaviors.typewriterScroll(textView)
            }
        }

        /// Moves the cursor to the nth heading line.
        func jumpToHeading(_ index: Int) {
            guard let textView else { return }
            let ns = textView.string as NSString
            var seen = 0
            var location = 0
            var inCode = false
            while location < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
                let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") { inCode.toggle() }
                if !inCode, line.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil {
                    if seen == index {
                        EditorBehaviors.jump(textView, toParagraphAt: lineRange.location)
                        return
                    }
                    seen += 1
                }
                location = NSMaxRange(lineRange)
                if lineRange.length == 0 { break }
            }
        }

        /// Text before and after the line containing the cursor.
        func splitAtCursor() -> (String, String)? {
            guard let textView else { return nil }
            let ns = textView.string as NSString
            let line = ns.lineRange(for: NSRange(location: min(textView.selectedRange.location, ns.length), length: 0))
            let before = ns.substring(to: line.location).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = ns.substring(from: line.location).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !before.isEmpty, !after.isEmpty else { return nil }
            return (before, after)
        }


        // MARK: - Syntax highlighting

        func applySyntaxHighlighting() {
            guard let textView, let textStorage = textView.textStorage else { return }
            MarkdownHighlighter.highlight(textStorage, fontSize: fontSize, baseColor: baseColor)
            textView.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: textStorage.length),
                                                     changeInLength: 0, actualCharacterRange: nil)
        }
    }
}

extension MarkdownEditorView.Coordinator: @MainActor NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        MarkdownHighlighter.generateGlyphs(layoutManager, glyphs: glyphs, properties: properties,
                                           characterIndexes: characterIndexes, font: font, glyphRange: glyphRange)
    }
}
