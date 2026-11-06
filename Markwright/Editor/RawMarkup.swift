//
//  RawMarkup.swift
//  Markwright
//
//  Formatting commands for the raw Markdown editor: they insert or toggle markup
//  in the NSTextView, going through insertText so undo and highlighting follow.
//

import AppKit

@MainActor
enum RawMarkup {

    private static func text(_ textView: NSTextView) -> NSString { textView.string as NSString }

    private static func replace(_ textView: NSTextView, range: NSRange, with replacement: String, selecting: NSRange) {
        textView.insertText(replacement, replacementRange: range)
        textView.setSelectedRange(selecting)
        textView.scrollRangeToVisible(selecting)
    }

    /// Wraps the selection, unwraps it when the markers are already there, or inserts a placeholder.
    static func wrap(_ textView: NSTextView, prefix: String, suffix: String, placeholder: String) {
        let selection = textView.selectedRange
        let ns = text(textView)
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        if selection.length > 0 {
            let inner = ns.substring(with: selection)
            if selection.length >= prefixLength + suffixLength, inner.hasPrefix(prefix), inner.hasSuffix(suffix) {
                let stripped = String(inner.dropFirst(prefix.count).dropLast(suffix.count))
                replace(textView, range: selection, with: stripped,
                        selecting: NSRange(location: selection.location, length: (stripped as NSString).length))
                return
            }
            let before = NSRange(location: selection.location - prefixLength, length: prefixLength)
            let after = NSRange(location: NSMaxRange(selection), length: suffixLength)
            if before.location >= 0, NSMaxRange(after) <= ns.length,
               ns.substring(with: before) == prefix, ns.substring(with: after) == suffix {
                let outer = NSRange(location: before.location, length: prefixLength + selection.length + suffixLength)
                replace(textView, range: outer, with: inner, selecting: NSRange(location: before.location, length: selection.length))
                return
            }
            replace(textView, range: selection, with: prefix + inner + suffix,
                    selecting: NSRange(location: selection.location + prefixLength, length: selection.length))
        } else {
            replace(textView, range: selection, with: prefix + placeholder + suffix,
                    selecting: NSRange(location: selection.location + prefixLength, length: (placeholder as NSString).length))
        }
    }

    /// Adds or removes a line prefix on every selected line.
    static func togglePrefix(_ textView: NSTextView, _ prefix: String, alternatives: [String] = []) {
        let ns = text(textView)
        let lineRange = ns.lineRange(for: textView.selectedRange)
        var block = ns.substring(with: lineRange)
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
            if alternatives.contains("1. "), let match = stripped.range(of: #"^\d+\. "#, options: .regularExpression) {
                stripped.removeSubrange(match)
            }
            return allHave ? stripped : prefix + stripped
        }
        var replacement = updated.joined(separator: "\n")
        if hadNewline { replacement += "\n" }
        replace(textView, range: lineRange, with: replacement,
                selecting: NSRange(location: lineRange.location, length: (replacement as NSString).length - (hadNewline ? 1 : 0)))
    }

    static func toggleNumbered(_ textView: NSTextView) {
        let ns = text(textView)
        let lineRange = ns.lineRange(for: textView.selectedRange)
        var block = ns.substring(with: lineRange)
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
        replace(textView, range: lineRange, with: replacement,
                selecting: NSRange(location: lineRange.location, length: (replacement as NSString).length - (hadNewline ? 1 : 0)))
    }

    /// 0 removes heading marks.
    static func setHeading(_ textView: NSTextView, level: Int) {
        let ns = text(textView)
        let lineRange = ns.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        var line = ns.substring(with: lineRange)
        let hadNewline = line.hasSuffix("\n")
        if hadNewline { line.removeLast() }
        if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { line.removeSubrange(match) }
        if level > 0 { line = String(repeating: "#", count: level) + " " + line }
        replace(textView, range: lineRange, with: line + (hadNewline ? "\n" : ""),
                selecting: NSRange(location: lineRange.location + (line as NSString).length, length: 0))
    }

    /// Inserts a block on its own lines at the cursor, selecting a placeholder inside it.
    static func insertBlock(_ textView: NSTextView, _ block: String, selectingPlaceholder placeholder: String? = nil) {
        let selection = textView.selectedRange
        let ns = text(textView)
        let atLineStart = selection.location == 0 || ns.character(at: selection.location - 1) == 0x0A
        let atLineEnd = NSMaxRange(selection) >= ns.length || ns.character(at: NSMaxRange(selection)) == 0x0A
        var replacement = ""
        if !atLineStart { replacement += "\n\n" } else if selection.location >= 2, ns.character(at: selection.location - 2) != 0x0A { replacement += "\n" }
        let bodyStart = (replacement as NSString).length
        replacement += block
        replacement += atLineEnd ? "\n" : "\n\n"
        var selecting = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
        if let placeholder {
            let found = (block as NSString).range(of: placeholder)
            if found.location != NSNotFound {
                selecting = NSRange(location: selection.location + bodyStart + found.location, length: found.length)
            }
        }
        replace(textView, range: selection, with: replacement, selecting: selecting)
    }

    /// `[^n]` at the cursor and `[^n]: ` at the end of the document.
    static func insertFootnote(_ textView: NSTextView) {
        let ns = text(textView)
        var maxID = 0
        if let regex = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#) {
            for match in regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
                maxID = max(maxID, Int(ns.substring(with: match.range(at: 1))) ?? 0)
            }
        }
        let id = String(maxID + 1)
        let at = NSRange(location: NSMaxRange(textView.selectedRange), length: 0)
        replace(textView, range: at, with: "[^\(id)]", selecting: NSRange(location: at.location + id.count + 3, length: 0))
        let updated = text(textView)
        var tail = "\n\n[^\(id)]: "
        if updated.length > 0 {
            let lastLine = updated.substring(from: updated.lineRange(for: NSRange(location: updated.length - 1, length: 0)).location)
            // Keep definitions together, and don't add a blank line after a trailing newline.
            if lastLine.hasPrefix("[^") || updated.character(at: updated.length - 1) == 0x0A { tail = "\n[^\(id)]: " }
        }
        replace(textView, range: NSRange(location: updated.length, length: 0), with: tail,
                selecting: NSRange(location: updated.length + (tail as NSString).length, length: 0))
    }
}
