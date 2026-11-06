//
//  StyleEngine.swift
//  Markwright
//
//  Turns the semantic attributes stored in the rendered editor (see
//  MarkdownModel.swift) into fonts, colors and paragraph styles, using the
//  user's ThemeSettings.
//

import AppKit
import SwiftUI

/// Snapshot of the theme used by the rendered editor. Equality is based on the
/// theme's change counter so SwiftUI updates don't trigger needless restyling.
struct EditorStyle: Equatable {
    let version: Int
    let bodySize: CGFloat
    let headingColor: NSColor
    let linkColor: NSColor
    let blockquoteBarColor: NSColor
    let blockquoteItalic: Bool
    let inlineCodeBackground: NSColor
    let codeBlockBackground: NSColor
    let strikethroughColor: NSColor
    let taskCheckedColor: NSColor
    let tableHeaderBackground: NSColor
    let headingDividers: Bool
    let fontFamily: String
    let lineSpacing: CGFloat
    let maxWidth: CGFloat
    /// nil means follow the system appearance.
    let editorBackground: NSColor?
    let textColor: NSColor

    init(theme: ThemeSettings) {
        version = theme.version
        bodySize = CGFloat(theme.bodyFontSize)
        headingColor = Self.nsColor(theme.headingColor, default: ThemeSettings.defaultHeadingColor, fallback: .labelColor)
        linkColor = Self.nsColor(theme.linkColor, default: ThemeSettings.defaultLinkColor, fallback: .linkColor)
        blockquoteBarColor = Self.nsColor(theme.blockquoteBarColor, default: ThemeSettings.defaultBlockquoteBarColor, fallback: .controlAccentColor)
        blockquoteItalic = theme.blockquoteItalic
        inlineCodeBackground = Self.nsColor(theme.inlineCodeBackground, default: ThemeSettings.defaultInlineCodeBackground, fallback: .controlBackgroundColor)
        codeBlockBackground = Self.nsColor(theme.codeBlockBackground, default: ThemeSettings.defaultCodeBlockBackground, fallback: .controlBackgroundColor)
        strikethroughColor = Self.nsColor(theme.strikethroughColor, default: ThemeSettings.defaultStrikethroughColor, fallback: .secondaryLabelColor)
        taskCheckedColor = Self.nsColor(theme.taskCheckedColor, default: ThemeSettings.defaultTaskCheckedColor, fallback: .systemGreen)
        tableHeaderBackground = Self.nsColor(theme.tableHeaderBackground, default: ThemeSettings.defaultTableHeaderBackground, fallback: .controlBackgroundColor)
        headingDividers = theme.headingDividers
        fontFamily = theme.editorFont
        lineSpacing = CGFloat(theme.lineSpacing)
        maxWidth = CGFloat(theme.editorMaxWidth)
        if theme.useCustomEditorColors {
            editorBackground = NSColor(theme.editorBackground)
            textColor = NSColor(theme.editorTextColor)
        } else {
            editorBackground = nil
            textColor = .labelColor
        }
    }

    /// Theme defaults map straight to AppKit's dynamic colors; only user-picked colors go through SwiftUI conversion.
    private static func nsColor(_ color: Color, default defaultColor: Color, fallback: NSColor) -> NSColor {
        if color == defaultColor { return fallback }
        return NSColor(color)
    }

    static func == (lhs: EditorStyle, rhs: EditorStyle) -> Bool {
        lhs.version == rhs.version
    }
}

@MainActor
final class StyleEngine {

    var style: EditorStyle {
        didSet { paragraphStyles.removeAll() }
    }

    private var paragraphStyles: [BlockInfo: NSParagraphStyle] = [:]

    init(style: EditorStyle) {
        self.style = style
    }

    private static let headingScales: [CGFloat] = [2.0, 1.7, 1.4, 1.25, 1.1, 1.0]
    private static let listIndentStep: CGFloat = 24
    private static let listMarkerWidth: CGFloat = 24

    // MARK: - Fonts

    var bodyFont: NSFont { baseFont(size: style.bodySize, weight: .regular) }

    /// The editor's proportional font for a size and weight, honoring the font-family setting.
    func baseFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch style.fontFamily {
        case "system", "":
            return .systemFont(ofSize: size, weight: weight)
        case "serif", "rounded":
            let design: NSFontDescriptor.SystemDesign = style.fontFamily == "serif" ? .serif : .rounded
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(design)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size, weight: weight)
        case "monospaced":
            return .monospacedSystemFont(ofSize: size, weight: weight)
        default:
            guard let font = NSFont(name: style.fontFamily, size: size) else {
                return .systemFont(ofSize: size, weight: weight)
            }
            if weight == .regular { return font }
            let bold = weight == .bold || weight == .semibold || weight == .heavy
            return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        }
    }

    func font(for block: BlockInfo, inline: InlineStyle, isHeaderCell: Bool = false) -> NSFont {
        var size = style.bodySize
        var weight: NSFont.Weight = .regular
        var monospaced = inline.code

        switch block.kind {
        case .heading(let level):
            let index = min(max(level, 1), 6) - 1
            size *= Self.headingScales[index]
            weight = level <= 2 ? .bold : (level <= 4 ? .semibold : .medium)
        case .codeBlock, .frontMatter:
            monospaced = true
            size = max(size - 1, 8)
        case .horizontalRule:
            size = 4
        case .footnote:
            size *= 0.9
        default:
            break
        }
        if inline.footnoteRef != nil { size *= 0.7 }
        if isHeaderCell { weight = .bold }

        if monospaced {
            let isCodeBlock: Bool
            if case .codeBlock = block.kind { isCodeBlock = true } else { isCodeBlock = false }
            return NSFont.monospacedSystemFont(ofSize: size, weight: (inline.bold && !isCodeBlock) ? .bold : .regular)
        }

        var font = baseFont(size: size, weight: weight)
        var traits: NSFontTraitMask = []
        if inline.bold { traits.insert(.boldFontMask) }
        var quoteItalic = false
        if case .blockquote = block.kind { quoteItalic = style.blockquoteItalic }
        if case .comment = block.kind { quoteItalic = true }
        if inline.italic || quoteItalic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }

    // MARK: - Paragraph styles

    func paragraphStyle(for block: BlockInfo) -> NSParagraphStyle {
        if let cached = paragraphStyles[block] { return cached }
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = style.lineSpacing

        switch block.kind {
        case .paragraph:
            ps.paragraphSpacing = 10
        case .comment:
            let note = Self.fullWidthBlock()
            note.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
            note.setBorderColor(NSColor.tertiaryLabelColor, for: .minX)
            note.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            note.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
            note.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            ps.textBlocks = [note]
            ps.paragraphSpacing = 10
        case .frontMatter:
            let meta = Self.fullWidthBlock()
            meta.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            meta.setWidth(0.5, type: .absoluteValueType, for: .border)
            meta.setBorderColor(NSColor.separatorColor)
            meta.setWidth(8, type: .absoluteValueType, for: .padding)
            ps.textBlocks = [meta]
            ps.paragraphSpacing = 14
        case .heading(let level):
            ps.paragraphSpacingBefore = level <= 2 ? 14 : 10
            ps.paragraphSpacing = 6
            if style.headingDividers && level <= 2 {
                let divider = Self.fullWidthBlock()
                divider.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                divider.setBorderColor(NSColor.separatorColor, for: .maxY)
                divider.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
                ps.textBlocks = [divider]
            }
        case .footnote:
            ps.firstLineHeadIndent = 4
            ps.headIndent = 4 + Self.listMarkerWidth
            ps.tabStops = [NSTextTab(textAlignment: .left, location: 4 + Self.listMarkerWidth)]
            ps.paragraphSpacing = 4
        case .bullet, .ordered, .task:
            let base = CGFloat(block.indent) * Self.listIndentStep + 4
            ps.firstLineHeadIndent = base
            ps.headIndent = base + Self.listMarkerWidth
            ps.tabStops = [NSTextTab(textAlignment: .left, location: base + Self.listMarkerWidth)]
            ps.defaultTabInterval = Self.listMarkerWidth
            ps.paragraphSpacing = 3
        case .blockquote:
            let quote = Self.fullWidthBlock()
            quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            quote.setBorderColor(style.blockquoteBarColor.withAlphaComponent(0.7), for: .minX)
            quote.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            quote.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
            quote.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            ps.textBlocks = [quote]
            ps.paragraphSpacing = 10
        case .codeBlock:
            let code = Self.fullWidthBlock()
            code.backgroundColor = style.codeBlockBackground
            code.setWidth(0.5, type: .absoluteValueType, for: .border)
            code.setBorderColor(NSColor.separatorColor)
            code.setWidth(10, type: .absoluteValueType, for: .padding)
            ps.textBlocks = [code]
            ps.paragraphSpacing = 10
            ps.lineSpacing = 1
        case .horizontalRule:
            let rule = Self.fullWidthBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(NSColor.separatorColor, for: .maxY)
            rule.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
            ps.textBlocks = [rule]
            ps.paragraphSpacingBefore = 8
            ps.paragraphSpacing = 14
        case .tableCell:
            break
        }

        let immutable = ps.copy() as! NSParagraphStyle
        paragraphStyles[block] = immutable
        return immutable
    }

    /// A text block that spans the full line width. Without an explicit width,
    /// TextKit 1 lays a block out one character per line.
    private static func fullWidthBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        return block
    }

    // MARK: - Tables

    func configureTableBlock(_ block: NSTextTableBlock, isHeader: Bool, columns: Int) {
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(NSColor.separatorColor)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        block.setValue(100.0 / CGFloat(max(columns, 1)), type: .percentageValueType, for: .width)
        block.backgroundColor = isHeader ? style.tableHeaderBackground : nil
        block.verticalAlignment = .topAlignment
    }

    func tableCellParagraphStyle(for block: NSTextTableBlock, isLastRow: Bool = false) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.textBlocks = [block]
        ps.lineSpacing = 2
        ps.paragraphSpacing = isLastRow ? 10 : 0
        return ps.copy() as! NSParagraphStyle
    }

    // MARK: - Attribute dictionaries

    /// Full attribute dictionary for ordinary content characters.
    func attributes(block: BlockInfo,
                    inline: InlineStyle,
                    paragraphStyle: NSParagraphStyle? = nil,
                    isHeaderCell: Bool = false) -> [NSAttributedString.Key: Any] {
        var inline = inline
        if block.kind.isPlainText {
            inline = InlineStyle()   // code, comments and metadata carry no inline styling
        }
        let ps: NSParagraphStyle
        if case .tableCell = block.kind {
            ps = paragraphStyle ?? NSParagraphStyle.default
        } else {
            ps = self.paragraphStyle(for: block)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .mmBlock: block,
            .paragraphStyle: ps,
            .font: font(for: block, inline: inline, isHeaderCell: isHeaderCell),
        ]

        var color = style.textColor
        var strike = inline.strike
        switch block.kind {
        case .heading: color = style.headingColor
        case .footnote: color = style.editorBackground == nil ? .secondaryLabelColor : style.textColor.withAlphaComponent(0.7)
        case .blockquote: color = style.editorBackground == nil ? .secondaryLabelColor : style.textColor.withAlphaComponent(0.7)
        case .comment: color = style.editorBackground == nil ? .secondaryLabelColor : style.textColor.withAlphaComponent(0.6)
        case .frontMatter: color = style.editorBackground == nil ? .secondaryLabelColor : style.textColor.withAlphaComponent(0.7)
        case .task(let checked) where checked:
            color = .secondaryLabelColor
            strike = true
        default: break
        }
        if inline.wikiLink != nil {
            color = style.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
        } else if inline.link != nil {
            color = style.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else if inline.footnoteRef != nil {
            color = style.linkColor
            attrs[.baselineOffset] = style.bodySize * 0.4
        } else if inline.tag {
            color = .controlAccentColor
            attrs[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.12)
        } else if inline.strike {
            color = style.strikethroughColor
        }
        attrs[.foregroundColor] = color
        if strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inline.code {
            attrs[.backgroundColor] = style.inlineCodeBackground.withAlphaComponent(0.5)
        }
        if inline.highlight {
            attrs[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35)
        }
        inline.apply(to: &attrs)
        return attrs
    }

    /// Attributes for the text part of a list marker ("•\t", "1.\t", "\t" after a checkbox).
    func markerAttributes(block: BlockInfo) -> [NSAttributedString.Key: Any] {
        if case .footnote = block.kind {
            return [
                .mmBlock: block,
                .mmMarker: true,
                .paragraphStyle: paragraphStyle(for: block),
                .font: NSFont.monospacedDigitSystemFont(ofSize: style.bodySize * 0.7, weight: .medium),
                .foregroundColor: style.linkColor,
                .baselineOffset: style.bodySize * 0.35,
            ]
        }
        return [
            .mmBlock: block,
            .mmMarker: true,
            .paragraphStyle: paragraphStyle(for: block),
            .font: NSFont.monospacedDigitSystemFont(ofSize: style.bodySize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }

    /// Attributes for an attachment character (image or checkbox).
    func attachmentAttributes(block: BlockInfo,
                              attachment: NSTextAttachment,
                              isMarker: Bool,
                              paragraphStyle: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        let ps: NSParagraphStyle
        if case .tableCell = block.kind {
            ps = paragraphStyle ?? NSParagraphStyle.default
        } else {
            ps = self.paragraphStyle(for: block)
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .attachment: attachment,
            .mmBlock: block,
            .paragraphStyle: ps,
            .font: bodyFont,
        ]
        if isMarker { attrs[.mmMarker] = true }
        return attrs
    }

    // MARK: - Markers

    func checkbox(checked: Bool) -> TaskCheckboxAttachment {
        TaskCheckboxAttachment(checked: checked,
                               color: checked ? style.taskCheckedColor : NSColor.secondaryLabelColor,
                               size: style.bodySize)
    }

    /// The marker prefix for a list paragraph.
    func marker(for block: BlockInfo, number: Int) -> NSAttributedString {
        switch block.kind {
        case .bullet:
            return NSAttributedString(string: "\u{2022}\t", attributes: markerAttributes(block: block))
        case .ordered:
            return NSAttributedString(string: "\(number).\t", attributes: markerAttributes(block: block))
        case .footnote(let id):
            return NSAttributedString(string: "\(id)\t", attributes: markerAttributes(block: block))
        case .task(let checked):
            let box = checkbox(checked: checked)
            let result = NSMutableAttributedString(attachment: box)
            result.setAttributes(attachmentAttributes(block: block, attachment: box, isMarker: true),
                                 range: NSRange(location: 0, length: 1))
            result.append(NSAttributedString(string: "\t", attributes: markerAttributes(block: block)))
            return result
        default:
            return NSAttributedString()
        }
    }

    /// Whether an existing checkbox attachment still matches the block and theme.
    func checkboxIsCurrent(_ box: TaskCheckboxAttachment, for block: BlockInfo) -> Bool {
        guard case .task(let checked) = block.kind else { return false }
        let expectedColor = checked ? style.taskCheckedColor : NSColor.secondaryLabelColor
        return box.checked == checked && box.size == style.bodySize && box.color.isEqual(expectedColor)
    }
}
