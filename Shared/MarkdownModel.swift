//
//  MarkdownModel.swift
//  Marky Mark
//
//  Semantic model shared by the rendered editor, the renderer and the serializer.
//  The rendered editor stores *semantic* attributes (block kind, bold, italic, …)
//  on the text; visual attributes (fonts, colors, paragraph styles) are always
//  derived from them by `StyleEngine`.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

nonisolated enum MarkdownSyntax {
    /// Line separator used inside multi-line blocks (code blocks, blockquotes) so the
    /// whole block stays a single paragraph in the rendered editor.
    static let lineSeparator: Character = "\u{2028}"
    static let lineSeparatorString = "\u{2028}"
    static let lineSeparatorUTF16: unichar = 0x2028
    static let newlineUTF16: unichar = 0x0A
    static let attachmentUTF16: unichar = 0xFFFC
}

extension NSAttributedString.Key {
    /// `BlockInfo` describing the paragraph this character belongs to.
    nonisolated static let mmBlock = NSAttributedString.Key("mm.block")
    /// Present (true) on list-marker characters ("•\t", "1.\t", checkbox + "\t").
    nonisolated static let mmMarker = NSAttributedString.Key("mm.marker")
    nonisolated static let mmBold = NSAttributedString.Key("mm.bold")
    nonisolated static let mmItalic = NSAttributedString.Key("mm.italic")
    nonisolated static let mmStrike = NSAttributedString.Key("mm.strike")
    nonisolated static let mmCode = NSAttributedString.Key("mm.code")
}

// MARK: - Blocks

nonisolated enum BlockKind: Equatable {
    case paragraph
    case heading(level: Int)
    case bullet
    case ordered
    case task(checked: Bool)
    case blockquote
    case codeBlock(language: String)
    case horizontalRule
    case tableCell
    /// An editorial comment (`<!-- ... -->`), kept in the file but excluded from export and counts.
    case comment
    /// YAML front matter at the top of the document (`---` ... `---`).
    case frontMatter

    var isList: Bool {
        switch self {
        case .bullet, .ordered, .task: return true
        default: return false
        }
    }

    /// Blocks whose lines are joined with `MarkdownSyntax.lineSeparator` inside one paragraph.
    var isMultiline: Bool {
        switch self {
        case .blockquote, .codeBlock, .comment, .frontMatter: return true
        default: return false
        }
    }

    /// Blocks whose text carries no inline formatting.
    var isPlainText: Bool {
        switch self {
        case .codeBlock, .comment, .frontMatter: return true
        default: return false
        }
    }

    /// Blocks whose structure the editor protects from ordinary text edits.
    var isProtected: Bool {
        switch self {
        case .tableCell, .horizontalRule: return true
        default: return false
        }
    }

    /// True when both values are the same kind, ignoring associated values.
    func isSameFamily(as other: BlockKind) -> Bool {
        switch (self, other) {
        case (.paragraph, .paragraph), (.heading, .heading), (.bullet, .bullet), (.ordered, .ordered),
             (.task, .task), (.blockquote, .blockquote), (.codeBlock, .codeBlock),
             (.horizontalRule, .horizontalRule), (.tableCell, .tableCell),
             (.comment, .comment), (.frontMatter, .frontMatter):
            return true
        default:
            return false
        }
    }
}

/// Immutable description of a paragraph's block type. Stored under `.mmBlock`.
nonisolated final class BlockInfo: NSObject {
    let kind: BlockKind
    let indent: Int

    init(_ kind: BlockKind, indent: Int = 0) {
        self.kind = kind
        self.indent = max(0, indent)
    }

    static let paragraph = BlockInfo(.paragraph)

    var isList: Bool { kind.isList }
    var isMultiline: Bool { kind.isMultiline }
    var isProtected: Bool { kind.isProtected }

    func with(indent: Int) -> BlockInfo { BlockInfo(kind, indent: indent) }
    func with(kind: BlockKind) -> BlockInfo { BlockInfo(kind, indent: indent) }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockInfo else { return false }
        return other.kind == kind && other.indent == indent
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(indent)
        hasher.combine(String(describing: kind))
        return hasher.finalize()
    }

    override var description: String { "BlockInfo(\(kind), indent: \(indent))" }
}

// MARK: - Inline styles

nonisolated struct InlineStyle: Equatable {
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var link: String? = nil

    init() {}

    init(attributes: [NSAttributedString.Key: Any]) {
        bold = attributes[.mmBold] as? Bool ?? false
        italic = attributes[.mmItalic] as? Bool ?? false
        strike = attributes[.mmStrike] as? Bool ?? false
        code = attributes[.mmCode] as? Bool ?? false
        if let value = attributes[.link] {
            link = (value as? URL)?.absoluteString ?? (value as? String)
        }
    }

    var isPlain: Bool { !bold && !italic && !strike && !code && link == nil }

    /// Writes the semantic keys into an attribute dictionary.
    func apply(to attributes: inout [NSAttributedString.Key: Any]) {
        if bold { attributes[.mmBold] = true }
        if italic { attributes[.mmItalic] = true }
        if strike { attributes[.mmStrike] = true }
        if code { attributes[.mmCode] = true }
        if let link, !link.isEmpty {
            attributes[.link] = URL(string: link) ?? link
        }
    }
}

// MARK: - Ordered list numbering

/// Computes sequential numbers for ordered list items. Feed it every paragraph in
/// document order; it returns a number only for ordered items.
nonisolated struct OrderedCounter {
    private var counts: [Int: Int] = [:]

    mutating func next(for block: BlockInfo) -> Int? {
        guard block.isList else {
            counts.removeAll()
            return nil
        }
        // A shallower item restarts any deeper lists.
        for key in counts.keys where key > block.indent {
            counts[key] = nil
        }
        if case .ordered = block.kind {
            let n = (counts[block.indent] ?? 0) + 1
            counts[block.indent] = n
            return n
        }
        // A bullet or task at this level restarts numbering at this level.
        counts[block.indent] = 0
        return nil
    }
}

// MARK: - Attribute comparison

nonisolated enum AttributeCompare {
    static func equal(_ a: [NSAttributedString.Key: Any], _ b: [NSAttributedString.Key: Any]) -> Bool {
        guard a.count == b.count else { return false }
        for (key, value) in a {
            guard let other = b[key] else { return false }
            if !equalValues(value, other) { return false }
        }
        return true
    }

    static func equalValues(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? NSObject, let y = b as? NSObject {
            return x.isEqual(y)
        }
        return false
    }
}
