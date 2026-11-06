//
//  TextAttachments.swift
//  Markwright
//
//  Attachments used by the rendered editor: inline images and task checkboxes,
//  plus the loader that fetches image data.
//

import AppKit

// MARK: - Images

/// An inline image. Shows a placeholder chip until the image loads (or if it can't).
nonisolated final class MarkdownImageAttachment: NSTextAttachment {
    let alt: String
    let source: String
    var loadRequested = false
    var isLoaded = false

    init(alt: String, source: String, placeholderSize: CGFloat) {
        self.alt = alt
        self.source = source
        super.init(data: nil, ofType: nil)
        let label = alt.isEmpty ? (source.isEmpty ? "Image" : source) : alt
        let chip = ImagePlaceholder.chip(text: label, fontSize: placeholderSize)
        image = chip
        bounds = CGRect(x: 0, y: -6, width: chip.size.width, height: chip.size.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

nonisolated enum ImagePlaceholder {
    static func chip(text: String, fontSize: CGFloat) -> NSImage {
        let font = NSFont.systemFont(ofSize: fontSize - 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let iconWidth: CGFloat = fontSize + 4
        let width = min(max(textSize.width + iconWidth + 26, 80), 360)
        let height = textSize.height + 10
        let size = NSSize(width: width, height: height)

        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            if let icon = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: fontSize, weight: .regular)) {
                let iconRect = NSRect(x: 9, y: (height - icon.size.height) / 2,
                                      width: icon.size.width, height: icon.size.height)
                NSColor.secondaryLabelColor.set()
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.secondaryLabelColor.set()
                iconRect.fill(using: .sourceAtop)
            }

            let textRect = NSRect(x: 9 + iconWidth + 6, y: (height - textSize.height) / 2,
                                  width: width - iconWidth - 26, height: textSize.height)
            var textAttrs = attrs
            textAttrs[.foregroundColor] = NSColor.secondaryLabelColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            textAttrs[.paragraphStyle] = paragraph
            (text as NSString).draw(in: textRect, withAttributes: textAttrs)
            return true
        }
    }
}

/// Loads and caches images referenced from markdown (remote URLs or local paths).
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private var cache: [String: NSImage] = [:]
    private var failed: Set<String> = []

    private init() {}

    /// The image if it has already been loaded.
    func cachedImage(for source: String, baseURL: URL?) -> NSImage? {
        cache[cacheKey(source: source, baseURL: baseURL)]
    }

    func image(for source: String, baseURL: URL?) async -> NSImage? {
        let key = cacheKey(source: source, baseURL: baseURL)
        if let cached = cache[key] { return cached }
        if failed.contains(key) { return nil }
        guard let url = resolve(source, baseURL: baseURL) else {
            failed.insert(key)
            return nil
        }

        var image: NSImage? = nil
        if url.isFileURL {
            image = NSImage(contentsOf: url)
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            image = NSImage(data: data)
        }

        if let image, image.size.width > 0, image.size.height > 0 {
            cache[key] = image
            return image
        }
        failed.insert(key)
        return nil
    }

    private func cacheKey(source: String, baseURL: URL?) -> String {
        if let baseURL, !source.contains("://"), !source.hasPrefix("/") {
            return baseURL.deletingLastPathComponent().path + "|" + source
        }
        return source
    }

    private func resolve(_ source: String, baseURL: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "file" || scheme == "data" { return url }
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        if let baseURL {
            return URL(fileURLWithPath: expanded, relativeTo: baseURL.deletingLastPathComponent()).standardizedFileURL
        }
        return nil
    }
}

// MARK: - Task checkboxes

nonisolated final class TaskCheckboxAttachment: NSTextAttachment {
    let checked: Bool
    let color: NSColor
    let size: CGFloat

    init(checked: Bool, color: NSColor, size: CGFloat) {
        self.checked = checked
        self.color = color
        self.size = size
        super.init(data: nil, ofType: nil)
        let symbol = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square",
                             accessibilityDescription: checked ? "Completed" : "Not completed")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        let side = size + 2
        let tinted = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let symbol else { return false }
            let drawRect = NSRect(x: (side - symbol.size.width) / 2,
                                  y: (side - symbol.size.height) / 2,
                                  width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image = tinted
        let font = NSFont.systemFont(ofSize: size)
        bounds = CGRect(x: 0, y: (font.capHeight - side) / 2 + 1, width: side, height: side)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
