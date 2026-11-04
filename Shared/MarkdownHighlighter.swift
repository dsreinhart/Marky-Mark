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

        textStorage.endEditing()
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
