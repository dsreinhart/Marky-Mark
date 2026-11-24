//
//  PadImageHandleOverlay.swift
//  Markwright iPad
//
//  The frame and corner handles over the picture selected in the formatted view. It sits in the
//  text view (so it scrolls with the text) and takes touches and the pointer only on a handle;
//  the coordinator sizes the picture as a handle is dragged and writes `{width=N%}` at the end.
//

import UIKit

final class PadImageHandleOverlay: UIView {
    /// Called as a handle is dragged: the corner, the sideways distance from where the drag began,
    /// and whether the drag is over.
    var onDrag: ((ImageResize.Corner, CGFloat, Bool) -> Void)?
    /// Shown on the picture while dragging (its width).
    var label: String? { didSet { if label != oldValue { setNeedsDisplay() } } }
    private var dragCorner: ImageResize.Corner?

    /// How close a touch has to be to a handle; a finger needs more room than the pointer.
    static let reach: CGFloat = 20

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        addInteraction(UIPointerInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The picture's frame in this view.
    var pictureFrame: CGRect { bounds.insetBy(dx: ImageResize.margin, dy: ImageResize.margin) }

    func corner(at point: CGPoint) -> ImageResize.Corner? {
        ImageResize.corner(at: point, of: pictureFrame, reach: Self.reach)
    }

    /// Only the handles take touches; the rest of the picture and the text get them as usual.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isHidden && corner(at: point) != nil
    }

    override func draw(_ rect: CGRect) {
        ImageResize.draw(frame: pictureFrame, accent: tintColor, label: label)
    }

    /// Where the finger or pointer went down: the pan only begins after it has moved a little,
    /// and the handle and the distance are measured from here.
    private var touchDown: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchDown = touches.first?.location(in: self)
        super.touchesBegan(touches, with: event)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let location = pan.location(in: self)
        if pan.state == .began {
            let start = touchDown ?? CGPoint(x: location.x - pan.translation(in: self).x,
                                             y: location.y - pan.translation(in: self).y)
            touchDown = start
            dragCorner = corner(at: start)
        }
        guard let dragCorner, let start = touchDown else { return }
        let dx = location.x - start.x
        switch pan.state {
        case .began, .changed:
            onDrag?(dragCorner, dx, false)
        case .ended, .cancelled, .failed:
            onDrag?(dragCorner, dx, true)
            self.dragCorner = nil
            touchDown = nil
        default:
            break
        }
    }
}

extension PadImageHandleOverlay: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let corner = corner(at: request.location) else { return nil }
        let center = ImageResize.handleCenter(corner, of: pictureFrame)
        let side = Self.reach
        return UIPointerRegion(rect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                               identifier: "\(corner)" as NSString)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .roundedRect(region.rect.insetBy(dx: 3, dy: 3), radius: 3))
    }
}
