//
//  PadEditorView.swift
//  Marky Mark iPad
//
//  Syntax-highlighted Markdown editor on UITextView, plus the controller the
//  formatting toolbar and dashboard use to edit and navigate it.
//

import SwiftUI
import UIKit

struct PadEditorView: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let textColor: UIColor
    let background: UIColor?
    let maxWidth: CGFloat
    let typewriter: Bool
    let controller: PadEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PadTextView {
        let textView = PadTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.layoutManager.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = textColor
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.maxWidth = maxWidth
        textView.typewriter = typewriter
        textView.text = text
        apply(appearanceTo: textView)
        context.coordinator.highlight(textView)
        controller.textView = textView
        controller.textDidChange = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.sync(textView)
        }
        return textView
    }

    func updateUIView(_ textView: PadTextView, context: Context) {
        context.coordinator.parent = self
        var needsHighlight = false
        if textView.maxWidth != maxWidth { textView.maxWidth = maxWidth; textView.setNeedsLayout() }
        if textView.typewriter != typewriter { textView.typewriter = typewriter; textView.setNeedsLayout() }
        if context.coordinator.fontSize != fontSize || context.coordinator.textColor != textColor {
            context.coordinator.fontSize = fontSize
            context.coordinator.textColor = textColor
            needsHighlight = true
        }
        apply(appearanceTo: textView)
        if textView.text != text {
            let selected = textView.selectedRange
            textView.text = text
            let length = (text as NSString).length
            textView.selectedRange = NSRange(location: min(selected.location, length), length: 0)
            needsHighlight = true
        }
        if needsHighlight { context.coordinator.highlight(textView) }
    }

    private func apply(appearanceTo textView: UITextView) {
        textView.backgroundColor = background ?? .systemBackground
        textView.tintColor = background == nil ? nil : textColor
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PadEditorView
        var fontSize: CGFloat
        var textColor: UIColor

        init(_ parent: PadEditorView) {
            self.parent = parent
            fontSize = parent.fontSize
            textColor = parent.textColor
        }

        func highlight(_ textView: UITextView) {
            MarkdownHighlighter.highlight(textView.textStorage, fontSize: fontSize, baseColor: textColor)
            textView.layoutManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: textView.textStorage.length),
                                                    changeInLength: 0, actualCharacterRange: nil)
        }

        /// Pushes the text view's content to SwiftUI and recolors.
        func sync(_ textView: UITextView) {
            parent.text = textView.text
            highlight(textView)
            scrollIfTypewriter(textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            sync(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            scrollIfTypewriter(textView)
        }

        private func scrollIfTypewriter(_ textView: UITextView) {
            guard let pad = textView as? PadTextView, pad.typewriter,
                  let position = textView.selectedTextRange?.end else { return }
            let caret = textView.caretRect(for: position)
            guard caret.height.isFinite, caret.height > 0 else { return }
            let target = caret.midY - textView.bounds.height / 2
            let maxOffset = max(textView.contentSize.height - textView.bounds.height, 0)
            let y = min(max(target, 0), maxOffset)
            if abs(y - textView.contentOffset.y) > 2 {
                textView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
            }
        }
    }
}

extension PadEditorView.Coordinator: @MainActor NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: UIFont, forGlyphRange glyphRange: NSRange) -> Int {
        MarkdownHighlighter.generateGlyphs(layoutManager, glyphs: glyphs, properties: properties,
                                           characterIndexes: characterIndexes, font: font, glyphRange: glyphRange)
    }
}

/// Centers a limited-width column and reserves room below for typewriter scrolling.
final class PadTextView: UITextView {
    var maxWidth: CGFloat = 0
    var typewriter = false

    override func layoutSubviews() {
        var inset = UIEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
        if maxWidth > 0 {
            let side = max(20, floor((bounds.width - maxWidth) / 2))
            inset.left = side
            inset.right = side
        }
        if typewriter {
            inset.bottom = max(24, floor(bounds.height / 2))
        }
        if textContainerInset != inset {
            textContainerInset = inset
        }
        super.layoutSubviews()
    }
}

// MARK: - Controller

@MainActor
@Observable
final class PadEditorController {
    @ObservationIgnored weak var textView: UITextView?
    @ObservationIgnored var textDidChange: (() -> Void)?

    var hasSelection: Bool {
        (textView?.selectedRange.length ?? 0) > 0
    }

    private func replace(_ range: NSRange, with replacement: String, selecting: NSRange) {
        guard let textView,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return }
        textView.replace(textRange, withText: replacement)   // goes through the undo manager
        textView.selectedRange = selecting
        textDidChange?()
        textView.scrollRangeToVisible(selecting)
    }

    private var currentText: NSString { (textView?.text ?? "") as NSString }

    /// Toggles inline markup on the selection: wraps it, or unwraps it when the markers are
    /// already there (selected along with the text, or immediately around it). With no
    /// selection it inserts a placeholder.
    func wrap(prefix: String, suffix: String, placeholder: String) {
        guard let textView else { return }
        let selection = textView.selectedRange
        let text = currentText
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        if selection.length > 0 {
            let inner = text.substring(with: selection)
            // "**word**" selected → "word"
            if selection.length >= prefixLength + suffixLength, inner.hasPrefix(prefix), inner.hasSuffix(suffix) {
                let stripped = String(inner.dropFirst(prefix.count).dropLast(suffix.count))
                replace(selection, with: stripped,
                        selecting: NSRange(location: selection.location, length: (stripped as NSString).length))
                return
            }
            // "word" selected inside "**word**" → "word"
            let before = NSRange(location: selection.location - prefixLength, length: prefixLength)
            let after = NSRange(location: NSMaxRange(selection), length: suffixLength)
            if before.location >= 0, NSMaxRange(after) <= text.length,
               text.substring(with: before) == prefix, text.substring(with: after) == suffix {
                let outer = NSRange(location: before.location, length: prefixLength + selection.length + suffixLength)
                replace(outer, with: inner,
                        selecting: NSRange(location: before.location, length: selection.length))
                return
            }
            replace(selection, with: prefix + inner + suffix,
                    selecting: NSRange(location: selection.location + prefixLength, length: selection.length))
        } else {
            replace(selection, with: prefix + placeholder + suffix,
                    selecting: NSRange(location: selection.location + prefixLength, length: (placeholder as NSString).length))
        }
    }

    /// Adds or removes a line prefix ("- ", "> ", "- [ ] ") on every selected line.
    func togglePrefix(_ prefix: String, alternatives: [String] = []) {
        guard let textView else { return }
        let lineRange = currentText.lineRange(for: textView.selectedRange)
        var block = currentText.substring(with: lineRange)
        let hadNewline = block.hasSuffix("\n")
        if hadNewline { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        let allHave = lines.allSatisfy { $0.hasPrefix(prefix) || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let updated = lines.map { line -> String in
            var stripped = line
            for candidate in [prefix] + alternatives where stripped.hasPrefix(candidate) {
                stripped.removeFirst(candidate.count)
                break
            }
            if let match = stripped.range(of: #"^\d+\. "#, options: .regularExpression), alternatives.contains("1. ") {
                stripped.removeSubrange(match)
            }
            return allHave ? stripped : prefix + stripped
        }
        var replacement = updated.joined(separator: "\n")
        if hadNewline { replacement += "\n" }
        replace(lineRange, with: replacement,
                selecting: NSRange(location: lineRange.location, length: (replacement as NSString).length - (hadNewline ? 1 : 0)))
    }

    func toggleNumberedList() {
        guard let textView else { return }
        let lineRange = currentText.lineRange(for: textView.selectedRange)
        var block = currentText.substring(with: lineRange)
        let hadNewline = block.hasSuffix("\n")
        if hadNewline { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        let allNumbered = lines.allSatisfy { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        var counter = 0
        let updated = lines.map { line -> String in
            var stripped = line
            if let match = stripped.range(of: #"^\d+\. "#, options: .regularExpression) { stripped.removeSubrange(match) }
            for candidate in ["- [ ] ", "- [x] ", "- ", "* ", "+ ", "> "] where stripped.hasPrefix(candidate) {
                stripped.removeFirst(candidate.count)
                break
            }
            if allNumbered { return stripped }
            counter += 1
            return "\(counter). " + stripped
        }
        var replacement = updated.joined(separator: "\n")
        if hadNewline { replacement += "\n" }
        replace(lineRange, with: replacement,
                selecting: NSRange(location: lineRange.location, length: (replacement as NSString).length - (hadNewline ? 1 : 0)))
    }

    /// 0 = paragraph (removes any heading marks).
    func setHeading(_ level: Int) {
        guard let textView else { return }
        let lineRange = currentText.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        var line = currentText.substring(with: lineRange)
        let hadNewline = line.hasSuffix("\n")
        if hadNewline { line.removeLast() }
        if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { line.removeSubrange(match) }
        if level > 0 { line = String(repeating: "#", count: level) + " " + line }
        let replacement = line + (hadNewline ? "\n" : "")
        let cursor = lineRange.location + (line as NSString).length
        replace(lineRange, with: replacement, selecting: NSRange(location: cursor, length: 0))
    }

    /// Inserts a block on its own lines at the cursor.
    func insertBlock(_ block: String, selectingPlaceholder placeholder: String? = nil) {
        guard let textView else { return }
        let selection = textView.selectedRange
        let text = currentText
        let atLineStart = selection.location == 0 || text.character(at: selection.location - 1) == 0x0A
        let atLineEnd = NSMaxRange(selection) >= text.length || text.character(at: NSMaxRange(selection)) == 0x0A
        var replacement = ""
        if !atLineStart { replacement += "\n\n" } else if selection.location >= 2, text.character(at: selection.location - 2) != 0x0A { replacement += "\n" }
        let bodyStart = (replacement as NSString).length
        replacement += block
        replacement += atLineEnd ? "\n" : "\n\n"
        var selecting = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
        if let placeholder, let found = (block as NSString).range(of: placeholder) as NSRange?, found.location != NSNotFound {
            selecting = NSRange(location: selection.location + bodyStart + found.location, length: found.length)
        }
        replace(selection, with: replacement, selecting: selecting)
    }

    /// Lines of the document that are headings (outside code fences), with their ranges.
    private func headingLineRanges() -> [NSRange] {
        let text = currentText
        var result: [NSRange] = []
        var location = 0
        var inCode = false
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("```") { inCode.toggle() }
            if !inCode, content.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil {
                result.append(line)
            }
            if line.length == 0 { break }
            location = NSMaxRange(line)
        }
        return result
    }

    func jumpToHeading(_ index: Int) {
        guard let textView else { return }
        let ranges = headingLineRanges()
        guard ranges.indices.contains(index) else { return }
        let target = NSRange(location: ranges[index].location, length: 0)
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
        textView.becomeFirstResponder()
    }

    /// Selects the next occurrence of `needle` after the cursor (wrapping) and scrolls to it.
    func jump(toText needle: String) {
        guard let textView, !needle.isEmpty else { return }
        let ns = textView.text as NSString
        let start = min(NSMaxRange(textView.selectedRange), ns.length)
        var found = ns.range(of: needle, options: [], range: NSRange(location: start, length: ns.length - start))
        if found.location == NSNotFound { found = ns.range(of: needle) }
        guard found.location != NSNotFound else { return }
        textView.selectedRange = found
        textView.scrollRangeToVisible(found)
        textView.becomeFirstResponder()
    }

    /// Inserts `[^n]` at the cursor and a matching `[^n]: ` definition at the end of the document.
    func insertFootnote() {
        guard let textView else { return }
        let text = currentText
        var maxID = 0
        if let regex = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#) {
            for match in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                maxID = max(maxID, Int(text.substring(with: match.range(at: 1))) ?? 0)
            }
        }
        let id = String(maxID + 1)
        let at = NSRange(location: NSMaxRange(textView.selectedRange), length: 0)
        replace(at, with: "[^\(id)]", selecting: NSRange(location: at.location + id.count + 3, length: 0))
        let updated = currentText
        var tail = "\n\n[^\(id)]: "
        if updated.length > 0 {
            let lastLine = updated.substring(from: updated.lineRange(for: NSRange(location: updated.length - 1, length: 0)).location)
            if lastLine.hasPrefix("[^") || updated.character(at: updated.length - 1) == 0x0A { tail = "\n[^\(id)]: " }
        }
        let end = NSRange(location: updated.length, length: 0)
        replace(end, with: tail, selecting: NSRange(location: updated.length + (tail as NSString).length, length: 0))
    }

    /// Flips the nth task checkbox in the document.
    func toggleTask(_ index: Int) {
        let text = currentText
        guard let regex = try? NSRegularExpression(pattern: #"^(\s*[*\-+]\s+)\[([ xX])\]"#, options: .anchorsMatchLines) else { return }
        let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        guard matches.indices.contains(index) else { return }
        let box = matches[index].range(at: 2)
        let checked = text.substring(with: box) != " "
        let selection = textView?.selectedRange ?? NSRange(location: 0, length: 0)
        replace(box, with: checked ? " " : "x", selecting: selection)
    }
}
