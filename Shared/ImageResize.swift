//
//  ImageResize.swift
//  Markwright
//
//  Resize handles for a selected picture in the formatted view, shared by the Mac and iPad: where
//  the four corner handles sit, which one a point hits, the width a drag gives (a whole percentage
//  of the text column, kept as `{width=N%}`), and the drawing. Each platform supplies an overlay
//  view placed over the picture that draws this and turns a drag into these calls.
//

import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated enum ImageResize {

    enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// Dragging this corner to the right makes the picture wider.
        var growsRight: Bool { self == .topRight || self == .bottomRight }
    }

    /// The narrowest a drag makes a picture, in percent of the column.
    static let minimumPercent = 5
    /// How far the overlay reaches past the picture on each side, so the handles fit inside it.
    static let margin: CGFloat = 14
    /// The drawn handle's side.
    static let handleSize: CGFloat = 9

    /// The centre of a corner's handle on a picture's frame.
    static func handleCenter(_ corner: Corner, of frame: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    /// The corner whose handle is within `reach` of `point` (the nearest when several are), if any.
    static func corner(at point: CGPoint, of frame: CGRect, reach: CGFloat) -> Corner? {
        var best: (Corner, CGFloat)?
        for corner in Corner.allCases {
            let center = handleCenter(corner, of: frame)
            let distance = max(abs(point.x - center.x), abs(point.y - center.y))
            if distance <= reach, distance < (best?.1 ?? .infinity) { best = (corner, distance) }
        }
        return best?.0
    }

    /// The width, in whole percent of `columnWidth`, after dragging `corner` sideways by `dx` from a
    /// picture `startWidth` wide. Between `minimumPercent` and 100.
    static func percent(startWidth: CGFloat, dx: CGFloat, corner: Corner, columnWidth: CGFloat) -> Int {
        guard columnWidth > 0 else { return 100 }
        let width = startWidth + (corner.growsRight ? dx : -dx)
        let percent = Int((width / columnWidth * 100).rounded())
        return min(max(percent, minimumPercent), 100)
    }

    /// The size a picture of `natural` size takes at `percent` of `columnWidth`, keeping its shape.
    static func size(natural: CGSize, percent: Int, columnWidth: CGFloat) -> CGSize {
        guard natural.width > 0 else { return natural }
        let width = floor(columnWidth * CGFloat(percent) / 100)
        return CGSize(width: width, height: floor(natural.height * width / natural.width))
    }

    /// Draws the selection frame and handles for a picture at `frame` in the current graphics
    /// context (a flipped one: y grows downwards), with `label` (the width while dragging) below it.
    static func draw(frame: CGRect, accent: PlatformColor, label: String?) {
        #if os(macOS)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #endif
        context.saveGState()
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(frame.insetBy(dx: -0.75, dy: -0.75))
        for corner in Corner.allCases {
            let center = handleCenter(corner, of: frame)
            let handle = CGRect(x: center.x - handleSize / 2, y: center.y - handleSize / 2, width: handleSize, height: handleSize)
            context.setFillColor(PlatformColor.white.cgColor)
            context.fill(handle)
            context.setLineWidth(1.5)
            context.stroke(handle)
        }
        context.restoreGState()

        guard let label else { return }
        let font = PlatformFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: PlatformColor.white])
        let textSize = text.size()
        let badge = CGRect(x: frame.maxX - textSize.width - 12, y: frame.maxY - textSize.height - 12,
                           width: textSize.width + 8, height: textSize.height + 4)
        context.saveGState()
        context.setFillColor(accent.withAlphaComponent(0.9).cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        context.restoreGState()
        text.draw(at: CGPoint(x: badge.minX + 4, y: badge.minY + 2))
    }
}
