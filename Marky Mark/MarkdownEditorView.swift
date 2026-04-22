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
    @Binding var scrollFraction: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)

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

        // Observe scroll position
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Apply initial syntax highlighting
        context.coordinator.applySyntaxHighlighting()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
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
        private var isUpdatingScroll = false

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
            applySyntaxHighlighting()
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard !isUpdatingScroll,
                  let scrollView = scrollView else { return }
            let clipView = scrollView.contentView
            let docHeight = scrollView.documentView?.frame.height ?? 1
            let visibleHeight = clipView.bounds.height
            let maxScroll = max(docHeight - visibleHeight, 1)
            let fraction = clipView.bounds.origin.y / maxScroll
            parent.scrollFraction = min(max(fraction, 0), 1)
        }

        // MARK: - Syntax highlighting

        func applySyntaxHighlighting() {
            guard let textView = textView,
                  let textStorage = textView.textStorage else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)
            let text = textStorage.string

            textStorage.beginEditing()

            // Reset to base style
            textStorage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            let lines = text.components(separatedBy: "\n")
            var offset = 0
            var inCodeBlock = false

            for line in lines {
                let lineRange = NSRange(location: offset, length: line.utf16.count)
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("```") {
                    // Code fence markers
                    textStorage.addAttributes([
                        .foregroundColor: NSColor.systemTeal,
                        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
                    ], range: lineRange)
                    inCodeBlock.toggle()
                } else if inCodeBlock {
                    textStorage.addAttributes([
                        .foregroundColor: NSColor.systemGreen,
                        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                    ], range: lineRange)
                } else if trimmed.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil {
                    // Horizontal rule
                    textStorage.addAttributes([
                        .foregroundColor: NSColor.systemGray
                    ], range: lineRange)
                } else if trimmed.hasPrefix("#") {
                    // Headings — color and size by level
                    let level = trimmed.prefix(while: { $0 == "#" }).count
                    let sizes: [CGFloat] = [22, 20, 18, 16, 15, 14]
                    let size = level <= 6 ? sizes[level - 1] : 14
                    textStorage.addAttributes([
                        .foregroundColor: NSColor.systemBlue,
                        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
                    ], range: lineRange)
                } else if trimmed.hasPrefix(">") {
                    // Blockquote
                    textStorage.addAttributes([
                        .foregroundColor: NSColor.systemGray
                    ], range: lineRange)
                    // Color the > marker
                    if let markerRange = line.range(of: #"^\s*>"#, options: .regularExpression) {
                        let nsMarker = NSRange(markerRange, in: line)
                        let adjusted = NSRange(location: offset + nsMarker.location, length: nsMarker.length)
                        textStorage.addAttributes([
                            .foregroundColor: NSColor.systemIndigo,
                            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
                        ], range: adjusted)
                    }
                } else if trimmed.range(of: #"^[*\-+]\s+\[[ xX]\]"#, options: .regularExpression) != nil {
                    // Task list item
                    if let checkRange = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) {
                        let nsCheck = NSRange(checkRange, in: line)
                        let adjusted = NSRange(location: offset + nsCheck.location, length: nsCheck.length)
                        textStorage.addAttributes([
                            .foregroundColor: NSColor.systemGreen,
                            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
                        ], range: adjusted)
                    }
                    // Color the bullet
                    if let bulletRange = line.range(of: #"^\s*[*\-+]"#, options: .regularExpression) {
                        let nsBullet = NSRange(bulletRange, in: line)
                        let adjusted = NSRange(location: offset + nsBullet.location, length: nsBullet.length)
                        textStorage.addAttributes([
                            .foregroundColor: NSColor.systemOrange
                        ], range: adjusted)
                    }
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                    // Unordered list bullets
                    if let bulletRange = line.range(of: #"^\s*[*\-+]"#, options: .regularExpression) {
                        let nsBullet = NSRange(bulletRange, in: line)
                        let adjusted = NSRange(location: offset + nsBullet.location, length: nsBullet.length)
                        textStorage.addAttributes([
                            .foregroundColor: NSColor.systemOrange
                        ], range: adjusted)
                    }
                } else if trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                    // Ordered list numbers
                    if let numRange = line.range(of: #"^\s*\d+\."#, options: .regularExpression) {
                        let nsNum = NSRange(numRange, in: line)
                        let adjusted = NSRange(location: offset + nsNum.location, length: nsNum.length)
                        textStorage.addAttributes([
                            .foregroundColor: NSColor.systemOrange
                        ], range: adjusted)
                    }
                } else if trimmed.contains("|") && trimmed.range(of: #"^[|\s:-]+$"#, options: .regularExpression) != nil {
                    // Table separator row
                    textStorage.addAttributes([
                        .foregroundColor: NSColor.systemGray
                    ], range: lineRange)
                } else if trimmed.contains("|") {
                    // Table row — color the pipes
                    highlightInline(in: textStorage, line: line, offset: offset,
                                    pattern: #"\|"#,
                                    color: NSColor.systemCyan,
                                    font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium))
                }

                // Inline styles (only outside code blocks)
                if !inCodeBlock {
                    // Strikethrough ~~text~~
                    highlightInline(in: textStorage, line: line, offset: offset,
                                    pattern: #"~~.+?~~"#,
                                    color: NSColor.systemGray,
                                    font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                    strikethrough: true)
                    // Links [text](url)
                    highlightInline(in: textStorage, line: line, offset: offset,
                                    pattern: #"\[[^\]]*\]\([^)]+\)"#,
                                    color: NSColor.systemBlue,
                                    font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                    underline: true)
                    // Images ![alt](url)
                    highlightInline(in: textStorage, line: line, offset: offset,
                                    pattern: #"!\[[^\]]*\]\([^)]+\)"#,
                                    color: NSColor.systemIndigo,
                                    font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                    underline: true)
                    // Bold **text**
                    highlightInline(in: textStorage, line: line, offset: offset,
                                    pattern: #"\*\*(.+?)\*\*"#,
                                    color: NSColor.labelColor,
                                    font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold))
                    // Italic *text*
                    highlightInline(in: textStorage, line: line, offset: offset,
                                    pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#,
                                    color: NSColor.systemPurple,
                                    font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).withTraits(.italicFontMask))
                    // Inline code `text`
                    highlightInline(in: textStorage, line: line, offset: offset,
                                    pattern: #"`([^`]+)`"#,
                                    color: NSColor.systemTeal,
                                    font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium))
                }

                offset += line.utf16.count + 1 // +1 for newline
            }

            textStorage.endEditing()
        }

        private func highlightInline(in storage: NSTextStorage, line: String,
                                     offset: Int, pattern: String,
                                     color: NSColor, font: NSFont,
                                     strikethrough: Bool = false,
                                     underline: Bool = false) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                let range = NSRange(location: offset + match.range.location,
                                    length: match.range.length)
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: color,
                    .font: font
                ]
                if strikethrough {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if underline {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                storage.addAttributes(attrs, range: range)
            }
        }
    }
}

// MARK: - NSFont helper

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        return manager.convert(self, toHaveTrait: traits)
    }
}
