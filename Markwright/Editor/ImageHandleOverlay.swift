//
//  ImageHandleOverlay.swift
//  Markwright
//
//  The frame and corner handles over the picture selected in the formatted view. It sits in the
//  text view (so it scrolls with the text), takes the mouse only on a handle, and reports drags;
//  the coordinator sizes the picture and writes `{width=N%}` when the drag ends.
//

import AppKit

final class ImageHandleOverlay: NSView {
    /// Called as a handle is dragged: the corner, the sideways distance from where the drag began,
    /// and whether the mouse is up.
    var onDrag: ((ImageResize.Corner, CGFloat, Bool) -> Void)?
    /// Shown on the picture while dragging (its width).
    var label: String? { didSet { if label != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    /// The picture's frame in this view.
    var pictureFrame: CGRect { bounds.insetBy(dx: ImageResize.margin, dy: ImageResize.margin) }

    private func corner(at pointInSelf: CGPoint) -> ImageResize.Corner? {
        ImageResize.corner(at: pointInSelf, of: pictureFrame, reach: 7)
    }

    /// Only the handles take clicks; the rest of the picture and the text around it get them as usual.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return corner(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ImageResize.draw(frame: pictureFrame, accent: .controlAccentColor, label: label)
    }

    override func resetCursorRects() {
        for corner in ImageResize.Corner.allCases {
            let center = ImageResize.handleCenter(corner, of: pictureFrame)
            let position: NSCursor.FrameResizePosition = switch corner {
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            addCursorRect(CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14),
                          cursor: .frameResize(position: position, directions: .all))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let corner = corner(at: convert(event.locationInWindow, from: nil)), let window else { return }
        let start = event.locationInWindow.x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = next.locationInWindow.x - start
            if next.type == .leftMouseUp {
                onDrag?(corner, dx, true)
                break
            }
            onDrag?(corner, dx, false)
        }
    }
}
