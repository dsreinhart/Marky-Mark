//
//  EditorBehaviors.swift
//  Markwright
//
//  Writing-environment features shared by both editors: typewriter scrolling,
//  focus mode dimming, editor width, and the app-wide view settings behind them.
//

import SwiftUI
import AppKit

enum FocusMode: String, CaseIterable, Identifiable {
    case off
    case paragraph
    case sentence

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .paragraph: return "Paragraph"
        case .sentence: return "Sentence"
        }
    }
}

/// App-wide view preferences (persisted) that both editors and the menus read.
@MainActor
@Observable
final class ViewSettings {
    static let shared = ViewSettings()

    var typewriterScrolling: Bool {
        didSet { UserDefaults.standard.set(typewriterScrolling, forKey: "view.typewriter") }
    }
    var focusMode: FocusMode {
        didSet { UserDefaults.standard.set(focusMode.rawValue, forKey: "view.focusMode") }
    }
    var showDashboard: Bool {
        didSet { UserDefaults.standard.set(showDashboard, forKey: "view.showDashboard") }
    }
    var showLibrary: Bool {
        didSet { UserDefaults.standard.set(showLibrary, forKey: "view.showLibrary") }
    }

    private init() {
        let defaults = UserDefaults.standard
        typewriterScrolling = defaults.bool(forKey: "view.typewriter")
        focusMode = FocusMode(rawValue: defaults.string(forKey: "view.focusMode") ?? "") ?? .off
        showDashboard = defaults.bool(forKey: "view.showDashboard")
        showLibrary = defaults.bool(forKey: "view.showLibrary")
    }
}

/// Per-editor behavior switches passed from SwiftUI into the text views.
struct EditorOptions: Equatable {
    var typewriter = false
    var focus: FocusMode = .off
    var maxWidth: CGFloat = 0
    var composition = false
}

/// Base text view for both editors: centers a limited-width column and reserves
/// vertical room for typewriter scrolling.
class MarkwrightTextView: NSTextView {
    var baseInset = NSSize(width: 24, height: 20)
    var options = EditorOptions() {
        didSet { if options != oldValue { needsLayout = true; updateInsets() } }
    }

    override func layout() {
        updateInsets()
        super.layout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    /// Supplies sheet names for `[[` autocompletion.
    var wikiCompletions: ((String) -> [String])?

    /// The partial sheet name typed after an unclosed `[[` on the current line, if any.
    func wikiPartialRange() -> NSRange? {
        let selection = selectedRange
        guard selection.length == 0 else { return nil }
        return wikiPartialRange(endingAt: selection.location)
    }

    /// The partial name between an unclosed `[[` on the same line and `location`.
    private func wikiPartialRange(endingAt location: Int) -> NSRange? {
        let ns = string as NSString
        guard location <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: location - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let partialStart = NSMaxRange(open)
        let partial = before.substring(from: partialStart)
        if partial.contains("]]") || partial.contains("[") { return nil }
        return NSRange(location: line.location + partialStart, length: (partial as NSString).length)
    }

    override var rangeForUserCompletion: NSRange {
        wikiPartialRange() ?? super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal: Bool) {
        guard wikiPartialRange(endingAt: charRange.location) != nil else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
            return
        }
        // Commit closes the link; moving through the list just previews the name.
        let commit = isFinal && movement != NSTextMovement.cancel.rawValue
        super.insertCompletion(commit ? word + "]]" : word, forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
    }

    /// Opens the completion list when the insertion point follows an unclosed `[[`.
    func showWikiCompletionsIfNeeded() {
        guard wikiCompletions != nil, wikiPartialRange() != nil else { return }
        complete(nil)
    }

    func updateInsets() {
        guard let clip = enclosingScrollView?.contentView else { return }
        var inset = baseInset
        if options.maxWidth > 0 {
            inset.width = max(baseInset.width, floor((clip.bounds.width - options.maxWidth) / 2))
        }
        if options.typewriter {
            inset.height = max(baseInset.height, floor(clip.bounds.height / 2))
        }
        if inset != textContainerInset {
            textContainerInset = inset
        }
    }
}

@MainActor
enum EditorBehaviors {

    /// Scrolls so the line with the insertion point sits in the vertical middle of the view.
    static func typewriterScroll(_ textView: NSTextView, animated: Bool = true) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView = textView.enclosingScrollView,
              let storage = textView.textStorage else { return }
        let selection = textView.selectedRange
        guard selection.length == 0 else { return }
        layoutManager.ensureLayout(for: container)

        var lineRect: NSRect
        if selection.location >= storage.length {
            lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty, layoutManager.numberOfGlyphs > 0 {
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
            }
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: selection.location)
            guard glyph < layoutManager.numberOfGlyphs else { return }
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }

        let clip = scrollView.contentView
        let caretY = lineRect.midY + textView.textContainerOrigin.y
        let target = caretY - clip.bounds.height / 2
        let maxY = max(textView.frame.height - clip.bounds.height, 0)
        let y = min(max(target, 0), maxY)
        guard abs(y - clip.bounds.origin.y) > 0.5 else { return }
        let origin = NSPoint(x: clip.bounds.origin.x, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// Dims everything except the paragraph or sentence at the insertion point.
    static func applyFocus(_ textView: NSTextView, mode: FocusMode, dimColor: NSColor) {
        guard let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard mode != .off, storage.length > 0 else { return }

        let location = min(textView.selectedRange.location, storage.length)
        let ns = storage.string as NSString
        var focus = ns.paragraphRange(for: NSRange(location: min(location, max(storage.length - 1, 0)), length: 0))
        if mode == .sentence {
            var found: NSRange? = nil
            ns.enumerateSubstrings(in: focus, options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
                if NSLocationInRange(location, range) || location == NSMaxRange(range) {
                    found = range
                    stop.pointee = true
                }
            }
            if let found { focus = found }
        }
        if focus.location > 0 {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dimColor,
                                                forCharacterRange: NSRange(location: 0, length: focus.location))
        }
        let end = NSMaxRange(focus)
        if end < storage.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dimColor,
                                                forCharacterRange: NSRange(location: end, length: storage.length - end))
        }
    }

    /// Selects the start of the nth heading paragraph and scrolls to it.
    static func jump(_ textView: NSTextView, toParagraphAt location: Int) {
        let range = NSRange(location: min(location, textView.string.utf16.count), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }
}
