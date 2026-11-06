//
//  InlineParser.swift
//  Marky Mark
//
//  A small CommonMark-style inline parser. It understands code spans, links,
//  images, backslash escapes, and nested emphasis (*, _, ** , ~~) using the
//  CommonMark delimiter-run algorithm, so that markup produced by
//  `MarkdownSerializer` always parses back to the same structure.
//

import Foundation

nonisolated indirect enum InlineNode: Equatable {
    case text(String)
    case code(String)
    case emphasis([InlineNode])
    case strong([InlineNode])
    case strike([InlineNode])
    case link(label: [InlineNode], url: String)
    case image(alt: String, source: String)
    case highlight([InlineNode])
    /// `#tag` or `#nested/tag`; the stored string has no leading `#`.
    case tag(String)
    case wikiLink(target: String, label: String?)
    case footnoteRef(String)
}

nonisolated struct InlineParser {

    static func parse(_ text: String) -> [InlineNode] {
        var parser = InlineParser(chars: Array(text))
        return parser.run()
    }

    // MARK: - Tokens

    private struct Delimiter {
        let char: Character
        var count: Int
        let originalCount: Int
        let canOpen: Bool
        let canClose: Bool
    }

    private enum Token {
        case node(InlineNode)
        case delimiter(Delimiter)
    }

    private let chars: [Character]
    private var tokens: [Token] = []
    private var textBuffer = ""

    private init(chars: [Character]) {
        self.chars = chars
    }

    private mutating func flushText() {
        if !textBuffer.isEmpty {
            tokens.append(.node(.text(textBuffer)))
            textBuffer = ""
        }
    }

    // MARK: - Tokenizing

    private mutating func run() -> [InlineNode] {
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "\\", i + 1 < n, Self.isASCIIPunctuation(chars[i + 1]) {
                textBuffer.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "`" {
                if let (node, end) = parseCodeSpan(at: i) {
                    flushText()
                    tokens.append(.node(node))
                    i = end
                } else {
                    // Unmatched backtick run: literal.
                    var j = i
                    while j < n, chars[j] == "`" { textBuffer.append("`"); j += 1 }
                    i = j
                }
                continue
            }
            if c == "[", i + 1 < n, chars[i + 1] == "[" {
                if let (node, end) = parseWikiLink(at: i) {
                    flushText()
                    tokens.append(.node(node))
                    i = end
                    continue
                }
            }
            if c == "[", i + 1 < n, chars[i + 1] == "^" {
                if let (node, end) = parseFootnoteRef(at: i) {
                    flushText()
                    tokens.append(.node(node))
                    i = end
                    continue
                }
            }
            if c == "#" {
                if let (node, end) = parseTag(at: i) {
                    flushText()
                    tokens.append(.node(node))
                    i = end
                    continue
                }
            }
            if c == "[" || (c == "!" && i + 1 < n && chars[i + 1] == "[") {
                if let (node, end) = parseLinkOrImage(at: i) {
                    flushText()
                    tokens.append(.node(node))
                    i = end
                    continue
                }
                textBuffer.append(c)
                i += 1
                continue
            }
            if c == "*" || c == "_" || c == "~" || c == "=" {
                var j = i
                while j < n, chars[j] == c { j += 1 }
                let count = j - i
                if (c == "~" || c == "=") && count != 2 {
                    textBuffer.append(String(repeating: String(c), count: count))
                    i = j
                    continue
                }
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                let next: Character? = j < n ? chars[j] : nil
                let (canOpen, canClose) = Self.flanking(char: c, prev: prev, next: next)
                if !canOpen && !canClose {
                    textBuffer.append(String(repeating: c, count: count))
                } else {
                    flushText()
                    tokens.append(.delimiter(Delimiter(char: c, count: count, originalCount: count,
                                                       canOpen: canOpen, canClose: canClose)))
                }
                i = j
                continue
            }
            textBuffer.append(c)
            i += 1
        }
        flushText()
        processEmphasis()
        return finalize(tokens)
    }

    private func parseCodeSpan(at start: Int) -> (InlineNode, Int)? {
        let n = chars.count
        var i = start
        while i < n, chars[i] == "`" { i += 1 }
        let runLength = i - start
        var j = i
        while j < n {
            if chars[j] == "`" {
                var k = j
                while k < n, chars[k] == "`" { k += 1 }
                if k - j == runLength {
                    var content = String(chars[i..<j])
                    if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                       content.trimmingCharacters(in: .whitespaces).isEmpty == false {
                        content = String(content.dropFirst().dropLast())
                    }
                    return (.code(content), k)
                }
                j = k
            } else {
                j += 1
            }
        }
        return nil
    }

    private func parseLinkOrImage(at start: Int) -> (InlineNode, Int)? {
        let n = chars.count
        let isImage = chars[start] == "!"
        var i = isImage ? start + 1 : start
        guard i < n, chars[i] == "[" else { return nil }
        i += 1
        let labelStart = i
        var depth = 1
        while i < n {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        guard i < n, chars[i] == "]" else { return nil }
        let label = String(chars[labelStart..<i])
        i += 1
        guard i < n, chars[i] == "(" else { return nil }
        i += 1
        let destStart = i
        var parenDepth = 1
        while i < n {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "(" { parenDepth += 1 }
            if c == ")" {
                parenDepth -= 1
                if parenDepth == 0 { break }
            }
            if c == "\n" { return nil }
            i += 1
        }
        guard i < n, chars[i] == ")" else { return nil }
        var dest = String(chars[destStart..<i]).trimmingCharacters(in: .whitespaces)
        // Drop an optional "title" part: (url "title")
        if let space = dest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let rest = dest[space...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") || rest.hasPrefix("'") {
                dest = String(dest[..<space])
            }
        }
        if dest.hasPrefix("<"), dest.hasSuffix(">") { dest = String(dest.dropFirst().dropLast()) }
        let end = i + 1
        if isImage {
            return (.image(alt: Self.unescape(label), source: dest), end)
        }
        return (.link(label: InlineParser.parse(label), url: dest), end)
    }

    /// `[[Target]]` or `[[Target|Label]]`.
    private func parseWikiLink(at start: Int) -> (InlineNode, Int)? {
        let n = chars.count
        var i = start + 2
        let innerStart = i
        while i + 1 < n {
            if chars[i] == "]" && chars[i + 1] == "]" { break }
            if chars[i] == "\n" || chars[i] == "[" { return nil }
            i += 1
        }
        guard i + 1 < n else { return nil }
        let inner = String(chars[innerStart..<i])
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        var label: String? = nil
        if parts.count == 2 {
            let l = parts[1].trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { label = l }
        }
        return (.wikiLink(target: target, label: label), i + 2)
    }

    /// `[^id]` (a reference; definitions are handled at block level).
    private func parseFootnoteRef(at start: Int) -> (InlineNode, Int)? {
        let n = chars.count
        var i = start + 2
        let idStart = i
        while i < n, chars[i] != "]" {
            if Self.isWhitespace(chars[i]) || chars[i] == "[" { return nil }
            i += 1
        }
        guard i < n, i > idStart else { return nil }
        if i + 1 < n, chars[i + 1] == ":", start == 0 || chars[start - 1] == "\n" { return nil }
        return (.footnoteRef(String(chars[idStart..<i])), i + 1)
    }

    /// `#tag` preceded by whitespace or the start of the text, containing at least one letter.
    private func parseTag(at start: Int) -> (InlineNode, Int)? {
        let n = chars.count
        if start > 0 {
            let prev = chars[start - 1]
            guard Self.isWhitespace(prev) || prev == "(" || prev == "," else { return nil }
        }
        var i = start + 1
        while i < n, WikiLink.isTagCharacter(chars[i]) { i += 1 }
        var end = i
        while end > start + 1, chars[end - 1] == "/" || chars[end - 1] == "-" { end -= 1 }
        guard end > start + 1 else { return nil }
        let name = String(chars[(start + 1)..<end])
        guard name.contains(where: { $0.isLetter }) else { return nil }
        return (.tag(name), end)
    }

    // MARK: - Emphasis (CommonMark "process emphasis")

    private mutating func processEmphasis() {
        var closerIndex = 0
        while closerIndex < tokens.count {
            guard case .delimiter(let closer) = tokens[closerIndex], closer.canClose else {
                closerIndex += 1
                continue
            }
            // Look back for a matching opener.
            var openerIndex = closerIndex - 1
            var found: Int? = nil
            while openerIndex >= 0 {
                if case .delimiter(let opener) = tokens[openerIndex],
                   opener.char == closer.char, opener.canOpen {
                    // Rule of three for * and _.
                    let ruleOfThree = (opener.char != "~" && opener.char != "=")
                        && (opener.canClose || closer.canOpen)
                        && (opener.originalCount + closer.originalCount) % 3 == 0
                        && !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
                    if !ruleOfThree {
                        found = openerIndex
                        break
                    }
                }
                openerIndex -= 1
            }
            guard let openerIdx = found,
                  case .delimiter(var opener) = tokens[openerIdx],
                  case .delimiter(var closerDelim) = tokens[closerIndex] else {
                closerIndex += 1
                continue
            }

            let use: Int
            if closer.char == "~" || closer.char == "=" {
                use = 2
            } else {
                use = (opener.count >= 2 && closerDelim.count >= 2) ? 2 : 1
            }
            let inner = finalize(Array(tokens[(openerIdx + 1)..<closerIndex]))
            let node: InlineNode
            switch (closer.char, use) {
            case ("~", _): node = .strike(inner)
            case ("=", _): node = .highlight(inner)
            case (_, 2): node = .strong(inner)
            default: node = .emphasis(inner)
            }

            opener.count -= use
            closerDelim.count -= use

            // Replace opener+1 ..< closer with the node.
            tokens.replaceSubrange((openerIdx + 1)..<closerIndex, with: [.node(node)])
            var newCloserIndex = openerIdx + 2

            if closerDelim.count > 0 {
                tokens[newCloserIndex] = .delimiter(closerDelim)
            } else {
                tokens.remove(at: newCloserIndex)
            }
            if opener.count > 0 {
                tokens[openerIdx] = .delimiter(opener)
            } else {
                tokens.remove(at: openerIdx)
                newCloserIndex -= 1
            }
            if closerDelim.count > 0 {
                closerIndex = newCloserIndex   // try to match the remaining closer again
            } else {
                closerIndex = newCloserIndex
            }
        }
    }

    private func finalize(_ tokens: [Token]) -> [InlineNode] {
        var nodes: [InlineNode] = []
        for token in tokens {
            let node: InlineNode
            switch token {
            case .node(let n): node = n
            case .delimiter(let d): node = .text(String(repeating: d.char, count: d.count))
            }
            if case .text(let t) = node, case .text(let prev)? = nodes.last {
                nodes[nodes.count - 1] = .text(prev + t)
            } else {
                nodes.append(node)
            }
        }
        return nodes
    }

    // MARK: - Character classes

    static func flanking(char: Character, prev: Character?, next: Character?) -> (Bool, Bool) {
        let prevWS = prev.map(isWhitespace) ?? true
        let nextWS = next.map(isWhitespace) ?? true
        let prevPunct = prev.map(isPunctuation) ?? false
        let nextPunct = next.map(isPunctuation) ?? false
        let left = !nextWS && (!nextPunct || prevWS || prevPunct)
        let right = !prevWS && (!prevPunct || nextWS || nextPunct)
        if char == "_" {
            return (left && (!right || prevPunct), right && (!left || nextPunct))
        }
        return (left, right)
    }

    static func isWhitespace(_ c: Character) -> Bool {
        c.isWhitespace || c.isNewline
    }

    static func isPunctuation(_ c: Character) -> Bool {
        if isASCIIPunctuation(c) { return true }
        return c.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
    }

    static func isASCIIPunctuation(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        switch ascii {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: return false
        }
    }

    /// Removes backslash escapes from plain text (used for image alt text).
    static func unescape(_ text: String) -> String {
        var out = ""
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if c == "\\", let next = iterator.next() {
                if isASCIIPunctuation(next) {
                    out.append(next)
                } else {
                    out.append(c)
                    pending = next
                }
            } else {
                out.append(c)
            }
        }
        return out
    }
}
