//
//  PadScrollSync.swift
//  Markwright iPad
//
//  Keeps Split's editor and preview scrolled to the same place. The panes have different heights,
//  so the position is translated block by block: the same point within the same block lines up
//  in both, and both reach their ends together. Whichever pane the person scrolls leads.
//

import SwiftUI
import UIKit

@MainActor
final class PadScrollSync {
    let link = PreviewScrollLink()
    weak var textView: UITextView?
    /// On only while both panes are showing.
    var isEnabled = false {
        didSet { if isEnabled && !oldValue { DispatchQueue.main.async { [weak self] in self?.followEditor() } } }
    }
    /// True while this object is moving the editor itself.
    private var isMovingEditor = false
    /// UTF-16 offset of the start of each line of the editor's text.
    private var lineStarts: [Int] = [0]
    private var lineStartsLength = -1

    init() {
        link.onPreviewScroll = { [weak self] in self?.followPreview() }
        link.onLayoutChange = { [weak self] in
            guard let self, !link.previewIsDriving else { return }
            followEditor()
        }
    }

    // MARK: Events from the editor

    func editorDidScroll() {
        guard isEnabled, !isMovingEditor, !link.previewIsDriving else { return }
        followEditor()
    }

    func editorWillBeginDragging() {
        link.previewIsDriving = false
    }

    // MARK: Following

    private func followEditor() {
        guard isEnabled, let textView, let place = editorPlace(textView),
              var y = link.y(ofBlock: place.index, fraction: place.fraction) else { return }
        let top = visibleTop(textView), maxTop = maxVisibleTop(textView)
        y = Self.blendTowardEnd(y, remaining: maxTop - top, viewport: textView.bounds.height, end: link.maxVisibleTop)
        link.scrollPreview(toY: y)
    }

    private func followPreview() {
        guard isEnabled, let textView, let place = link.block(atY: link.visibleTop),
              var y = editorY(textView, block: place.index, fraction: place.fraction) else { return }
        let maxTop = maxVisibleTop(textView)
        y = Self.blendTowardEnd(y, remaining: link.maxVisibleTop - link.visibleTop, viewport: link.viewportHeight, end: maxTop)
        y = min(max(y, 0), maxTop)
        let offset = y - textView.adjustedContentInset.top
        guard abs(offset - textView.contentOffset.y) >= 0.5 else { return }
        isMovingEditor = true
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: offset), animated: false)
        isMovingEditor = false
    }

    /// Within the last screenful of the leading pane, eases the follower toward its own end so
    /// both finish together.
    static func blendTowardEnd(_ y: CGFloat, remaining: CGFloat, viewport: CGFloat, end: CGFloat) -> CGFloat {
        guard viewport > 0, remaining < viewport else { return y }
        let t = 1 - max(remaining, 0) / viewport
        return y + (end - y) * t
    }

    // MARK: Editor geometry

    /// Content y at the top of the editor's visible area, and the largest it can be.
    private func visibleTop(_ textView: UITextView) -> CGFloat {
        textView.contentOffset.y + textView.adjustedContentInset.top
    }

    private func maxVisibleTop(_ textView: UITextView) -> CGFloat {
        let insets = textView.adjustedContentInset
        return max(textView.contentSize.height + insets.bottom + insets.top - textView.bounds.height, 0)
    }

    private func updateLineStarts(_ text: NSString) {
        guard text.length != lineStartsLength || lineStarts.last.map({ $0 > text.length }) == true else { return }
        var starts = [0]
        var location = 0
        while location < text.length {
            let found = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { break }
            location = found.location + 1
            starts.append(location)
        }
        lineStarts = starts
        lineStartsLength = text.length
    }

    /// Call when the text changes, since an edit can keep the length.
    func textChanged() { lineStartsLength = -1 }

    private func line(containing offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func block(containingLine line: Int) -> Int? {
        let blocks = link.blockLines
        guard !blocks.isEmpty else { return nil }
        var low = 0, high = blocks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if blocks[mid].lowerBound <= line { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Rect of a block's lines in the editor's content coordinates.
    private func rect(ofBlock index: Int, in textView: UITextView) -> CGRect? {
        let blocks = link.blockLines
        guard blocks.indices.contains(index) else { return nil }
        let text = textView.text as NSString
        updateLineStarts(text)
        let lines = blocks[index]
        guard lines.lowerBound < lineStarts.count else { return nil }
        let start = lineStarts[lines.lowerBound]
        let end = lines.upperBound < lineStarts.count ? lineStarts[lines.upperBound] : text.length
        let layoutManager = textView.layoutManager
        var rect: CGRect
        if end > start {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil)
            rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        } else {
            rect = layoutManager.extraLineFragmentRect
        }
        rect.origin.y += textView.textContainerInset.top
        return rect
    }

    /// The block at the top of the editor and how far into it the top falls.
    private func editorPlace(_ textView: UITextView) -> (index: Int, fraction: CGFloat)? {
        let text = textView.text as NSString
        updateLineStarts(text)
        let top = visibleTop(textView)
        guard let first = rect(ofBlock: 0, in: textView) else { return nil }
        if top < first.minY { return (-1, first.minY > 0 ? max(top, 0) / first.minY : 0) }
        let point = CGPoint(x: 0, y: top - textView.textContainerInset.top)
        let character = textView.layoutManager.characterIndex(for: point, in: textView.textContainer,
                                                             fractionOfDistanceBetweenInsertionPoints: nil)
        guard let index = block(containingLine: line(containing: character)),
              let rect = rect(ofBlock: index, in: textView) else { return nil }
        let fraction = rect.height > 0 ? min(max((top - rect.minY) / rect.height, 0), 1) : 0
        return (index, fraction)
    }

    /// Content y in the editor for a place in a block.
    private func editorY(_ textView: UITextView, block index: Int, fraction: CGFloat) -> CGFloat? {
        if index < 0 { return rect(ofBlock: 0, in: textView).map { $0.minY * fraction } }
        guard let rect = rect(ofBlock: index, in: textView) else { return nil }
        return rect.minY + rect.height * fraction
    }
}
