//
//  SourceMap.swift
//  Markwright
//
//  Connects positions in the Markdown source to positions in the formatted editor's text.
//  Each block knows exactly where it sits on both sides. Inside a block the two are aligned
//  character by character, skipping markup that only exists on the source side.
//

import Foundation

nonisolated struct SourceMap {
    struct Entry: Equatable {
        /// Where the block's text sits in the Markdown.
        var raw: NSRange
        /// Where the block sits in the formatted text, without its final newline.
        var rendered: NSRange
    }

    /// Sorted, on both sides.
    var entries: [Entry] = []

    // MARK: Lines

    /// UTF-16 offsets of a document's lines.
    struct LineOffsets {
        /// One start per line, plus one final value just past the last line's newline.
        var starts: [Int]

        /// The characters of a run of lines, without the final newline.
        func range(of lines: Range<Int>) -> NSRange {
            let lower = starts[min(lines.lowerBound, starts.count - 1)]
            let upper = starts[min(lines.upperBound, starts.count - 1)]
            return NSRange(location: lower, length: max(upper - lower - 1, 0))
        }
    }

    static func lineOffsets(of lines: [String]) -> LineOffsets {
        var starts = [0]
        starts.reserveCapacity(lines.count + 1)
        var location = 0
        for line in lines {
            location += line.utf16.count + 1
            starts.append(location)
        }
        return LineOffsets(starts: starts)
    }

    static func lineOffsets(of text: String) -> LineOffsets {
        lineOffsets(of: text.components(separatedBy: "\n"))
    }

    // MARK: Source to formatted

    /// The formatted position for a source position. With `forward`, a position sitting on markup
    /// lands on the next visible character; otherwise just after the previous one.
    func renderedLocation(forRaw location: Int, raw: NSString, rendered: NSString, forward: Bool = true) -> Int {
        guard let index = lastEntry(where: { $0.raw.location <= location }) else {
            return entries.first?.rendered.location ?? 0
        }
        let entry = entries[index]
        if location > NSMaxRange(entry.raw) {
            return index + 1 < entries.count ? entries[index + 1].rendered.location : NSMaxRange(entry.rendered)
        }
        var result = NSMaxRange(entry.rendered)
        var previousEnd = entry.rendered.location
        Self.align(entry, raw: raw, rendered: rendered) { rawIndex, renderedIndex in
            if rawIndex >= location {
                result = forward ? renderedIndex : previousEnd
                return false
            }
            previousEnd = renderedIndex + 1
            return true
        }
        return result
    }

    /// The source position for a formatted position. With `forward`, the position lands on the
    /// next visible character's source; otherwise just after the previous character's source.
    func rawLocation(forRendered location: Int, raw: NSString, rendered: NSString, forward: Bool = true) -> Int {
        guard let index = lastEntry(where: { $0.rendered.location <= location }) else {
            return entries.first?.raw.location ?? 0
        }
        let entry = entries[index]
        if location > NSMaxRange(entry.rendered) {
            return index + 1 < entries.count ? entries[index + 1].raw.location : NSMaxRange(entry.raw)
        }
        var result = NSMaxRange(entry.raw)
        var previousEnd = entry.raw.location
        var found = false
        Self.align(entry, raw: raw, rendered: rendered) { rawIndex, renderedIndex in
            if renderedIndex >= location {
                result = forward ? rawIndex : previousEnd
                found = true
                return false
            }
            previousEnd = rawIndex + 1
            return true
        }
        return found ? result : previousEnd
    }

    func renderedRange(forRaw range: NSRange, raw: NSString, rendered: NSString) -> NSRange {
        let start = renderedLocation(forRaw: range.location, raw: raw, rendered: rendered)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = renderedLocation(forRaw: NSMaxRange(range), raw: raw, rendered: rendered, forward: false)
        return NSRange(location: start, length: max(end - start, 0))
    }

    func rawRange(forRendered range: NSRange, raw: NSString, rendered: NSString) -> NSRange {
        let start = rawLocation(forRendered: range.location, raw: raw, rendered: rendered)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = rawLocation(forRendered: NSMaxRange(range), raw: raw, rendered: rendered, forward: false)
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// The formatted text of a search match in the source: the occurrence of `needle` in the same block
    /// nearest to where the match maps. Counting occurrences wouldn't do, because a word can also be
    /// hidden inside a link address. A match with no visible counterpart shows as nearly as it can.
    func renderedMatch(forRaw range: NSRange, needle: String, options: NSString.CompareOptions,
                       raw: NSString, rendered: NSString) -> NSRange {
        let mapped = renderedRange(forRaw: range, raw: raw, rendered: rendered)
        guard let index = lastEntry(where: { $0.raw.location <= range.location }),
              NSMaxRange(range) <= NSMaxRange(entries[index].raw) else { return mapped }
        let entry = entries[index]
        var best: NSRange? = nil
        var search = entry.rendered.location
        while search < NSMaxRange(entry.rendered) {
            let hit = rendered.range(of: needle, options: options,
                                     range: NSRange(location: search, length: NSMaxRange(entry.rendered) - search))
            if hit.location == NSNotFound { break }
            if abs(hit.location - mapped.location) < abs((best?.location ?? Int.max / 2) - mapped.location) { best = hit }
            search = NSMaxRange(hit)
        }
        if let best { return best }
        return mapped.length > 0 ? mapped : entry.rendered
    }

    // MARK: Internals

    private func lastEntry(where isBefore: (Entry) -> Bool) -> Int? {
        var low = 0
        var high = entries.count - 1
        var found: Int? = nil
        while low <= high {
            let middle = (low + high) / 2
            if isBefore(entries[middle]) {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// How far ahead a visible character is looked for. Long enough to cross a link address.
    private static let lookahead = 512

    /// Calls `visit` for each visible character found in both texts, in order, until it returns false.
    private static func align(_ entry: Entry, raw: NSString, rendered: NSString, visit: (_ rawIndex: Int, _ renderedIndex: Int) -> Bool) {
        var rawIndex = entry.raw.location
        let rawEnd = min(NSMaxRange(entry.raw), raw.length)
        let renderedEnd = min(NSMaxRange(entry.rendered), rendered.length)
        var renderedIndex = entry.rendered.location
        while renderedIndex < renderedEnd {
            let character = rendered.character(at: renderedIndex)
            // Whitespace is reflowed and attachments have no text, so neither can be matched.
            if !isSkipped(character) {
                let limit = min(rawIndex + lookahead, rawEnd)
                var probe = rawIndex
                while probe < limit, raw.character(at: probe) != character { probe += 1 }
                if probe < limit {
                    if !visit(probe, renderedIndex) { return }
                    rawIndex = probe + 1
                }
            }
            renderedIndex += 1
        }
    }

    private static func isSkipped(_ character: unichar) -> Bool {
        switch character {
        case 0x20, 0x09, 0x0A, 0x0D, 0x2028, 0x2029, 0xFFFC, 0xA0: return true
        default: return false
        }
    }
}
