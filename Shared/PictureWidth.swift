//
//  PictureWidth.swift
//  Markwright
//
//  The optional width written after a picture: `![Chart](chart.png){width=50%}`. A percentage is
//  of the text column (the page's text width in Word); lengths use CSS units, where 1px is 1/96 in.
//  Without one, a picture is shown at its own size, shrunk to fit the column.
//

import Foundation

nonisolated struct PictureWidth: Equatable, Sendable {
    enum Unit: String, CaseIterable, Sendable {
        case percent = "%", px, pt, inch = "in", cm, mm

        /// CSS pixels (1/96 in) per unit; nil for a percentage.
        var cssPixels: Double? {
            switch self {
            case .percent: nil
            case .px: 1
            case .pt: 96.0 / 72.0
            case .inch: 96
            case .cm: 96 / 2.54
            case .mm: 96 / 25.4
            }
        }
    }

    let value: Double
    let unit: Unit
    /// The value as written (`50%`, `2in`, `300`), kept so the Markdown reads back unchanged.
    let text: String

    /// Parses `50%`, `300px`, `300` (pixels), `2in`, `5cm`, `40mm` or `144pt`. Units ignore case.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), value > 0, value.isFinite else { return nil }
        let suffix = trimmed.dropFirst(number.count).lowercased()
        guard let unit = suffix.isEmpty ? .px : Unit(rawValue: suffix) else { return nil }
        if unit == .percent, value > 100 { return nil }
        self.value = value
        self.unit = unit
        self.text = trimmed
    }

    /// The block written after a picture.
    var attribute: String { "{width=\(text)}" }

    /// A CSS length for the same width.
    var css: String {
        unit == .percent ? "\(Self.format(value))%" : "\(Self.format(value))\(unit == .px ? "px" : unit.rawValue)"
    }

    /// The width in CSS pixels (on screen, points), where `fullWidth` is what 100% means. Never wider
    /// than `fullWidth`.
    func cssPixels(fullWidth: Double) -> Double {
        let pixels = unit.cssPixels.map { value * $0 } ?? fullWidth * value / 100
        return min(pixels, fullWidth)
    }

    /// Reads `{width=…}` starting at `start` (the `{`). Spaces around the parts and quotes around the
    /// value are allowed. Returns the width and the index just past the `}`.
    static func parseAttribute(in chars: [Character], at start: Int) -> (PictureWidth, Int)? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var i = start + 1
        var inner = ""
        while i < chars.count, chars[i] != "}" {
            if chars[i] == "\n" || chars[i] == "{" { return nil }
            inner.append(chars[i])
            i += 1
        }
        guard i < chars.count else { return nil }
        let parts = inner.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "width" else { return nil }
        var value = parts[1].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        guard let width = PictureWidth(value) else { return nil }
        return (width, i + 1)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
