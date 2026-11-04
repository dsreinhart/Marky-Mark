//
//  MarkdownHighlighter.swift
//  Marky Mark
//
//  Syntax coloring for the raw Markdown editor, shared by the Mac and iPad apps.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
enum MarkdownHighlighter {

    /// Marks text the editor should not draw (embedded image payloads).
    nonisolated static let hiddenKey = NSAttributedString.Key("mm.hidden")


    /// Recolors the whole storage. Call inside the text view's own editing cycle.
    static func highlight(_ textStorage: NSTextStorage, fontSize size: CGFloat, baseColor: PlatformColor) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string
        let regular = PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let medium = PlatformFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let bold = PlatformFont.monospacedSystemFont(ofSize: size, weight: .bold)

        textStorage.beginEditing()
        textStorage.setAttributes([.font: regular, .foregroundColor: baseColor], range: fullRange)

        let lines = text.components(separatedBy: "\n")
        var offset = 0
        var inCodeBlock = false
        var inComment = false
        var inFrontMatter = false

        for (index, line) in lines.enumerated() {
            let lineRange = NSRange(location: offset, length: line.utf16.count)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { offset += line.utf16.count + 1 }

            if index == 0, trimmed == "---", lines.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                inFrontMatter = true
                textStorage.addAttributes([.foregroundColor: PlatformColor.systemTeal], range: lineRange)
                continue
            }
            if inFrontMatter {
                textStorage.addAttributes([.foregroundColor: PlatformColor.systemTeal], range: lineRange)
                if trimmed == "---" { inFrontMatter = false }
                continue
            }
            if inComment || trimmed.hasPrefix("<!--") {
                textStorage.addAttributes([.foregroundColor: PlatformColor.mmTertiaryLabel, .font: regular.italicVariant()], range: lineRange)
                inComment = !line.contains("-->")
                continue
            }

            if trimmed.hasPrefix("```") {
                textStorage.addAttributes([.foregroundColor: PlatformColor.systemTeal, .font: medium], range: lineRange)
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                textStorage.addAttributes([.foregroundColor: PlatformColor.systemGreen, .font: regular], range: lineRange)
                continue
            }

            if trimmed.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil {
                textStorage.addAttributes([.foregroundColor: PlatformColor.systemGray], range: lineRange)
            } else if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let scales: [CGFloat] = [1.55, 1.4, 1.25, 1.15, 1.05, 1.0]
                let headingSize = size * (level <= 6 ? scales[level - 1] : 1.0)
                textStorage.addAttributes([
                    .foregroundColor: PlatformColor.systemBlue,
                    .font: PlatformFont.monospacedSystemFont(ofSize: headingSize, weight: .bold)
                ], range: lineRange)
            } else if trimmed.hasPrefix(">") {
                textStorage.addAttributes([.foregroundColor: PlatformColor.systemGray], range: lineRange)
                color(line, offset: offset, pattern: #"^\s*>"#, color: .systemIndigo, font: bold, in: textStorage)
            } else if trimmed.range(of: #"^[*\-+]\s+\[[ xX]\]"#, options: .regularExpression) != nil {
                color(line, offset: offset, pattern: #"\[[ xX]\]"#, color: .systemGreen, font: bold, in: textStorage)
                color(line, offset: offset, pattern: #"^\s*[*\-+]"#, color: .systemOrange, font: regular, in: textStorage)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                color(line, offset: offset, pattern: #"^\s*[*\-+]"#, color: .systemOrange, font: regular, in: textStorage)
            } else if trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                color(line, offset: offset, pattern: #"^\s*\d+\."#, color: .systemOrange, font: regular, in: textStorage)
            } else if trimmed.contains("|") && trimmed.range(of: #"^[|\s:-]+$"#, options: .regularExpression) != nil {
                textStorage.addAttributes([.foregroundColor: PlatformColor.systemGray], range: lineRange)
            } else if trimmed.contains("|") {
                color(line, offset: offset, pattern: #"\|"#, color: .systemCyan, font: medium, in: textStorage)
            }

            // Inline styles
            color(line, offset: offset, pattern: #"~~.+?~~"#, color: .systemGray, font: regular, strikethrough: true, in: textStorage)
            color(line, offset: offset, pattern: #"\[[^\]]*\]\([^)]+\)"#, color: .systemBlue, font: regular, underline: true, in: textStorage)
            color(line, offset: offset, pattern: #"!\[[^\]]*\]\([^)]+\)"#, color: .systemIndigo, font: regular, underline: true, in: textStorage)
            color(line, offset: offset, pattern: #"\*\*(.+?)\*\*"#, color: baseColor, font: bold, in: textStorage)
            color(line, offset: offset, pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, color: .systemPurple, font: regular.italicVariant(), in: textStorage)
            color(line, offset: offset, pattern: #"`([^`]+)`"#, color: .systemTeal,
                  font: PlatformFont.monospacedSystemFont(ofSize: max(size - 1, 8), weight: .medium), in: textStorage)
        }

        hideEmbeddedImages(in: textStorage, baseColor: baseColor)
        textStorage.endEditing()
    }

    /// Folds `data:` image payloads: the prefix stays visible, the base64 is hidden from layout.
    /// Plain string scanning: a regex gives up on multi-megabyte payloads.
    private static func hideEmbeddedImages(in storage: NSTextStorage, baseColor: PlatformColor) {
        let text = storage.string as NSString
        var cursor = 0
        while cursor < text.length {
            let open = text.range(of: "](data:", options: [], range: NSRange(location: cursor, length: text.length - cursor))
            guard open.location != NSNotFound else { break }
            let prefixStart = open.location + 2
            let headerLimit = NSRange(location: prefixStart, length: min(120, text.length - prefixStart))
            let marker = text.range(of: ";base64,", options: [], range: headerLimit)
            guard marker.location != NSNotFound else { cursor = NSMaxRange(open); continue }
            let payloadStart = NSMaxRange(marker)
            let close = text.range(of: ")", options: [], range: NSRange(location: payloadStart, length: text.length - payloadStart))
            guard close.location != NSNotFound else { break }
            let payload = NSRange(location: payloadStart, length: close.location - payloadStart)
            if payload.length >= 40 {
                storage.addAttributes([.foregroundColor: PlatformColor.mmTertiaryLabel],
                                      range: NSRange(location: prefixStart, length: payloadStart - prefixStart))
                storage.addAttributes([hiddenKey: true, .foregroundColor: PlatformColor.clear], range: payload)
            }
            cursor = NSMaxRange(close)
        }
    }

    /// Glyph-generation hook for NSLayoutManagerDelegate: gives hidden characters null glyphs.
    /// Returns the number of glyphs handled (0 lets the layout manager do its default).
    static func generateGlyphs(_ layoutManager: NSLayoutManager,
                               glyphs: UnsafePointer<CGGlyph>,
                               properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                               characterIndexes: UnsafePointer<Int>,
                               font: PlatformFont,
                               glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        let firstChar = characterIndexes[0]
        let lastChar = characterIndexes[glyphRange.length - 1]
        var hasHidden = false
        storage.enumerateAttribute(hiddenKey, in: NSRange(location: firstChar, length: lastChar - firstChar + 1), options: []) { value, _, stop in
            if value != nil { hasHidden = true; stop.pointee = true }
        }
        guard hasHidden else { return 0 }
        var updated = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        for index in 0..<glyphRange.length
        where storage.attribute(hiddenKey, at: characterIndexes[index], effectiveRange: nil) != nil {
            updated[index] = .null
        }
        updated.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    private static func color(_ line: String, offset: Int, pattern: String, color: PlatformColor, font: PlatformFont,
                              strikethrough: Bool = false, underline: Bool = false, in storage: NSTextStorage) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsLine = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            let range = NSRange(location: offset + match.range.location, length: match.range.length)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: font]
            if strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            storage.addAttributes(attrs, range: range)
        }
    }
}
