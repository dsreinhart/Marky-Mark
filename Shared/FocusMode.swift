//
//  FocusMode.swift
//  Markwright
//
//  Focus mode: dim everything but the paragraph or sentence being written. Stored under
//  "view.focusMode" on both platforms.
//

import Foundation

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

extension FocusMode {
    /// The range left undimmed for an insertion point at `location`: its paragraph (line), or
    /// the sentence within it.
    static func range(in text: NSString, at location: Int, mode: FocusMode) -> NSRange? {
        guard mode != .off, text.length > 0 else { return nil }
        let location = min(location, text.length)
        var focus = text.paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        if mode == .sentence {
            var found: NSRange? = nil
            text.enumerateSubstrings(in: focus, options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
                if NSLocationInRange(location, range) || location == NSMaxRange(range) {
                    found = range
                    stop.pointee = true
                }
            }
            if let found { focus = found }
        }
        return focus
    }
}
