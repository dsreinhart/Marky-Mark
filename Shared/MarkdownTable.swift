//
//  MarkdownTable.swift
//  Markwright
//
//  A Markdown (GFM) table as rows of cells with a column alignment, for the iPad's table editor:
//  read from the table's Markdown, edited as a grid, written back with the columns lined up.
//

import Foundation

nonisolated struct MarkdownTable: Equatable {
    enum Alignment: String, CaseIterable, Identifiable {
        case none, left, center, right
        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "Default"
            case .left: "Left"
            case .center: "Center"
            case .right: "Right"
            }
        }
    }

    var headers: [String]
    var alignments: [Alignment]
    var rows: [[String]]

    init(headers: [String], alignments: [Alignment]? = nil, rows: [[String]]) {
        self.headers = headers
        self.alignments = alignments ?? Array(repeating: .none, count: headers.count)
        self.rows = rows
        normalize()
    }

    /// A new table for the editor: two columns, a header row and two empty rows.
    static var blank: MarkdownTable {
        MarkdownTable(headers: ["", ""], rows: [["", ""], ["", ""]])
    }

    var columnCount: Int { headers.count }

    // MARK: - Reading

    /// The table in `markdown` (its first two lines must be the header and the separator).
    static func parse(_ markdown: String) -> MarkdownTable? {
        let lines = markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, lines[0].contains("|"),
              lines[1].range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil else { return nil }
        let headers = cells(of: lines[0])
        let alignments = cells(of: lines[1]).map(alignment(of:))
        let rows = lines.dropFirst(2).filter { $0.contains("|") }.map(cells(of:))
        return MarkdownTable(headers: headers, alignments: alignments, rows: Array(rows))
    }

    /// The cells of one row, split at pipes that aren't escaped; `\|` becomes `|`.
    static func cells(of line: String) -> [String] {
        var content = Substring(line.trimmingCharacters(in: .whitespaces))
        if content.hasPrefix("|") { content = content.dropFirst() }
        if content.hasSuffix("|") && !content.hasSuffix("\\|") { content = content.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in content {
            if escaped {
                current.append(character == "|" ? "|" : "\\" + String(character))
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func alignment(of separator: String) -> Alignment {
        let cell = separator.trimmingCharacters(in: .whitespaces)
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .right
        case (true, false): return .left
        default: return .none
        }
    }

    // MARK: - Writing

    /// The table as Markdown, each column padded to its widest cell.
    var markdown: String {
        let escapedHeaders = headers.map(Self.escaped)
        let escapedRows = rows.map { $0.map(Self.escaped) }
        let widths = (0..<columnCount).map { column in
            max(3, ([escapedHeaders[column]] + escapedRows.map { $0[column] }).map(\.count).max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { column, cell in
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return alignments[column] == .right ? pad + cell : cell + pad
            }.joined(separator: " | ") + " |"
        }
        let separator = "| " + (0..<columnCount).map { column in
            let width = widths[column]
            switch alignments[column] {
            case .none: return String(repeating: "-", count: width)
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            }
        }.joined(separator: " | ") + " |"
        return ([line(escapedHeaders), separator] + escapedRows.map(line)).joined(separator: "\n")
    }

    /// A cell's text in a table line: pipes escaped, line breaks turned into spaces.
    private static func escaped(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Editing

    /// Every row as wide as the header, at least one column.
    mutating func normalize() {
        if headers.isEmpty { headers = [""] }
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        headers += Array(repeating: "", count: columns - headers.count)
        alignments = Array(alignments.prefix(columns)) + Array(repeating: .none, count: max(columns - alignments.count, 0))
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
    }

    mutating func insertColumn(at index: Int) {
        let at = min(max(index, 0), columnCount)
        headers.insert("", at: at)
        alignments.insert(.none, at: at)
        for row in rows.indices { rows[row].insert("", at: at) }
    }

    mutating func removeColumn(at index: Int) {
        guard columnCount > 1, headers.indices.contains(index) else { return }
        headers.remove(at: index)
        alignments.remove(at: index)
        for row in rows.indices { rows[row].remove(at: index) }
    }

    mutating func moveColumn(from index: Int, by offset: Int) {
        let target = index + offset
        guard headers.indices.contains(index), headers.indices.contains(target) else { return }
        headers.swapAt(index, target)
        alignments.swapAt(index, target)
        for row in rows.indices { rows[row].swapAt(index, target) }
    }

    mutating func insertRow(at index: Int) {
        rows.insert(Array(repeating: "", count: columnCount), at: min(max(index, 0), rows.count))
    }

    mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    mutating func moveRow(from index: Int, by offset: Int) {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
    }
}
