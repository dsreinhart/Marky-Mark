//
//  PadFormatCommands.swift
//  Markwright iPad
//
//  The toolbar's and dashboard's commands, sent to whichever pane is in use: the formatted
//  editor formats the text itself; the raw editor gets the Markdown syntax inserted.
//

import SwiftUI
import UIKit

/// The formatted editor asking for an address or a sheet name.
struct PadLinkPrompt: Identifiable {
    enum Kind { case link, wikiLink, image }
    let kind: Kind
    var address: String = ""
    /// Nothing is selected, so a new link needs its text too.
    var needsLabel = false
    /// The cursor or selection is on a link that can be removed.
    var canRemove = false
    /// The selection when the prompt opened. The text view loses it while the prompt has the keyboard.
    var selection = NSRange(location: 0, length: 0)
    var id: String { "\(kind)" }

    var title: String {
        switch kind {
        case .link: canRemove ? "Edit Link" : "Add Link"
        case .wikiLink: "Link to Sheet"
        case .image: "Image from the Web"
        }
    }
}

extension PadEditorController {
    private var formatted: PadRichCoordinator? { formattedIsActive ? rich : nil }

    // MARK: Paragraph styles

    /// 0 = paragraph.
    func applyHeading(_ level: Int) {
        if let formatted {
            formatted.applyBlock(level == 0 ? .paragraph : .heading(level: level), toggle: false)
        } else {
            setHeading(level)
        }
    }

    func applyBulletList() {
        if let formatted { formatted.applyBlock(.bullet) } else {
            togglePrefix("- ", alternatives: ["* ", "+ ", "- [ ] ", "- [x] ", "1. "])
        }
    }

    func applyNumberedList() {
        if let formatted { formatted.applyBlock(.ordered) } else { toggleNumberedList() }
    }

    func applyTaskList() {
        if let formatted {
            if case .task = formatState.blockKind {
                formatted.applyBlock(formatState.blockKind)
            } else {
                formatted.applyBlock(.task(checked: false))
            }
        } else {
            togglePrefix("- [ ] ", alternatives: ["- [x] ", "- ", "* ", "+ ", "1. "])
        }
    }

    func applyQuote() {
        if let formatted { formatted.applyBlock(.blockquote) } else { togglePrefix("> ") }
    }

    func applyCodeBlock() {
        if let formatted {
            if case .codeBlock = formatState.blockKind {
                formatted.applyBlock(formatState.blockKind)
            } else {
                formatted.applyBlock(.codeBlock(language: ""))
            }
        } else {
            insertBlock("```\ncode\n```", selectingPlaceholder: "code")
        }
    }

    func applyComment() {
        if let formatted { formatted.applyBlock(.comment) } else {
            insertBlock("<!-- note -->", selectingPlaceholder: "note")
        }
    }

    // MARK: Inline styles

    func applyInline(_ key: NSAttributedString.Key) {
        if let formatted {
            formatted.toggleInline(key)
            return
        }
        switch key {
        case .mmBold: wrap(prefix: "**", suffix: "**", placeholder: "bold")
        case .mmItalic: wrap(prefix: "*", suffix: "*", placeholder: "italic")
        case .mmStrike: wrap(prefix: "~~", suffix: "~~", placeholder: "struck")
        case .mmCode: wrap(prefix: "`", suffix: "`", placeholder: "code")
        case .mmHighlight: wrap(prefix: "==", suffix: "==", placeholder: "highlight")
        default: break
        }
    }

    func isOn(_ key: NSAttributedString.Key) -> Bool {
        guard formattedIsActive else { return false }
        switch key {
        case .mmBold: return formatState.bold
        case .mmItalic: return formatState.italic
        case .mmStrike: return formatState.strike
        case .mmCode: return formatState.code
        case .mmHighlight: return formatState.highlight
        default: return false
        }
    }

    // MARK: Links

    func requestLink() {
        guard let formatted else {
            wrap(prefix: "[", suffix: "](https://)", placeholder: "link text")
            return
        }
        let existing = formatted.linkAtSelection()
        let hasSelection = (formatted.textView?.selectedRange.length ?? 0) > 0
        prompt = PadLinkPrompt(kind: .link, address: existing?.url ?? "", needsLabel: existing == nil && !hasSelection,
                               canRemove: existing != nil, selection: formatted.textView?.selectedRange ?? NSRange())
    }

    func requestWikiLink() {
        guard let formatted else {
            wrap(prefix: "[[", suffix: "]]", placeholder: "Sheet name")
            return
        }
        prompt = PadLinkPrompt(kind: .wikiLink, selection: formatted.textView?.selectedRange ?? NSRange())
    }

    func requestImageLink() {
        guard let formatted else {
            insertBlock("![alt text](https://)", selectingPlaceholder: "https://")
            return
        }
        prompt = PadLinkPrompt(kind: .image, address: "https://", selection: formatted.textView?.selectedRange ?? NSRange())
    }

    /// The prompt's OK button.
    func finishPrompt(_ request: PadLinkPrompt, address: String, label: String) {
        prompt = nil
        guard let rich, let textView = rich.textView else { return }
        _ = textView.becomeFirstResponder()
        let length = textView.textStorage.length
        let start = min(request.selection.location, length)
        textView.selectedRange = NSRange(location: start, length: min(request.selection.length, length - start))
        let address = address.trimmingCharacters(in: .whitespaces)
        switch request.kind {
        case .link:
            guard !address.isEmpty else { return }
            rich.insertLink(url: address, text: label.trimmingCharacters(in: .whitespaces))
        case .wikiLink:
            rich.insertWikiLink(target: address)
        case .image:
            guard !address.isEmpty, address != "https://" else { return }
            rich.insertImage(alt: "", source: address)
        }
    }

    func removeLink(_ request: PadLinkPrompt) {
        prompt = nil
        guard let rich, let textView = rich.textView else { return }
        _ = textView.becomeFirstResponder()
        let length = textView.textStorage.length
        let start = min(request.selection.location, length)
        textView.selectedRange = NSRange(location: start, length: min(request.selection.length, length - start))
        rich.applyLink(nil)
    }

    // MARK: Blocks

    func addFootnote() {
        if let formatted { formatted.insertFootnote() } else { insertFootnote() }
    }

    func addRule() {
        if let formatted { formatted.insertHorizontalRule() } else { insertBlock("---") }
    }

    func addTable() {
        if let formatted { formatted.insertTable(rows: 1, columns: 2) } else {
            insertBlock("| Header 1 | Header 2 |\n| --- | --- |\n| Cell | Cell |", selectingPlaceholder: "Header 1")
        }
    }

    /// An image already stored (beside the document, or embedded).
    func addImage(alt: String, source: String) {
        if let formatted { formatted.insertImage(alt: alt, source: source) } else {
            insertBlock("![\(alt)](\(source))")
        }
    }

    // MARK: Navigation

    func goToHeading(_ index: Int) {
        if let formatted { formatted.jumpToHeading(index) } else { jumpToHeading(index) }
    }

    func goToText(_ needle: String) {
        if let formatted { formatted.jump(toText: needle) } else { jump(toText: needle) }
    }
}
