//
//  FrontMatter.swift
//  Marky Mark
//
//  Minimal YAML front matter reading and editing (enough for `tags`/`keywords`).
//

import Foundation

nonisolated enum FrontMatter {

    /// The lines between the `---` fences at the top of a document, or nil.
    static func block(in markdown: String) -> (lines: [String], bodyStart: Int)? {
        let lines = markdown.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return (Array(lines[1..<close]), close + 1)
    }

    static func keywords(in markdown: String) -> [String] {
        guard let block = block(in: markdown) else { return [] }
        var result: [String] = []
        var index = 0
        while index < block.lines.count {
            let line = block.lines[index]
            guard let colon = line.firstIndex(of: ":") else { index += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "tags" || key == "keywords" {
                if value.isEmpty {
                    var j = index + 1
                    while j < block.lines.count, block.lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                        let item = block.lines[j].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
                        if !item.isEmpty { result.append(clean(item)) }
                        j += 1
                    }
                    index = j
                    continue
                }
                var inner = value
                if inner.hasPrefix("["), inner.hasSuffix("]") { inner = String(inner.dropFirst().dropLast()) }
                result.append(contentsOf: inner.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty })
            }
            index += 1
        }
        return result
    }

    private static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Returns the document with its `tags` entry replaced by `keywords`.
    static func settingKeywords(_ keywords: [String], in markdown: String) -> String {
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tagLine = "tags: [" + cleaned.joined(separator: ", ") + "]"

        guard let block = block(in: markdown) else {
            guard !cleaned.isEmpty else { return markdown }
            return "---\n" + tagLine + "\n---\n\n" + markdown
        }

        // Drop the existing tags/keywords entry (inline or list form).
        var kept: [String] = []
        var index = 0
        while index < block.lines.count {
            let line = block.lines[index]
            let key = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if key == "tags" || key == "keywords" {
                index += 1
                while index < block.lines.count, block.lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("-") { index += 1 }
                continue
            }
            kept.append(line)
            index += 1
        }
        if !cleaned.isEmpty { kept.append(tagLine) }

        let allLines = markdown.components(separatedBy: "\n")
        let body = allLines[min(block.bodyStart, allLines.count)...].joined(separator: "\n")
        if kept.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return body.drop(while: { $0 == "\n" }).description
        }
        return "---\n" + kept.joined(separator: "\n") + "\n---\n" + (body.hasPrefix("\n") ? body : "\n" + body)
    }
}
