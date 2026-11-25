//
//  TableColumns.swift
//  Markwright
//
//  Column positions for a table shown in tab-separated columns (the iPad and iPhone formatted
//  view): each column as wide as its widest cell, the room left over shared out in proportion,
//  and the text scaled down when the cells don't fit at full size. Plain maths, so it is tested
//  on the Mac too.
//

import CoreGraphics

nonisolated enum TableColumns {
    /// Space between one column's text and the next.
    static let gap: CGFloat = 14
    /// A table's text is never scaled below this to make its columns fit.
    static let minimumScale: CGFloat = 0.72
    /// Where the first column starts, inside the table's frame.
    static let leading: CGFloat = 8

    /// `naturalWidths`: each column's widest cell at full size. Returns the tab stop for each
    /// column after the first, and the scale to draw the table's text at (1 when it fits).
    static func layout(naturalWidths: [CGFloat], width: CGFloat) -> (stops: [CGFloat], scale: CGFloat) {
        let widths = naturalWidths.isEmpty ? [width] : naturalWidths.map { max($0, 12) }
        let gaps = gap * CGFloat(widths.count)
        let total = widths.reduce(0, +)
        let scale = total + gaps <= width ? 1 : max((width - gaps) / total, minimumScale)
        let spare = max(width - (total * scale + gaps), 0)
        var stops: [CGFloat] = []
        var x = leading
        for column in widths.indices.dropLast() {
            x += widths[column] * scale + gap + spare * widths[column] / total
            stops.append(x.rounded())
        }
        return (stops, scale)
    }
}
