//
//  MarkdownEditorView.swift
//  Marky Mark
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

        let textView = MarkyTextView(usingTextLayoutManager: false)
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
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.applyAppearance()
        context.coordinator.applySyntaxHighlighting()
        controller?.jumpToHeading = { [weak coordinator = context.coordinator] index in coordinator?.jumpToHeading(index) }
        controller?.splitAtCursor = { [weak coordinator = context.coordinator] in coordinator?.splitAtCursor() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkyTextView else { return }
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
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.applySyntaxHighlighting()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        var styleVersion: Int? = nil

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        var fontSize: CGFloat { parent.style?.bodySize ?? 14 }
        private var baseColor: NSColor { parent.style?.textColor ?? .labelColor }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
            applySyntaxHighlighting()
            applyBehaviors()
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
            guard let textView = textView as? MarkyTextView else { return }
            EditorBehaviors.applyFocus(textView, mode: textView.options.focus, dimColor: baseColor.withAlphaComponent(0.28))
            if textView.options.typewriter {
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
        }
    }
}
