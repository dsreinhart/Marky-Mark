//
//  TextAttachments.swift
//  Markwright
//
//  Attachments used by the rendered editor: inline images and task checkboxes,
//  plus the loader that fetches image data. Shared by the Mac and iPad.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

    #if os(iOS)
    /// The placeholder's light or dark version, whichever the text view is showing.
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        image.map { isLoaded ? $0 : ($0.imageAsset?.image(with: .current) ?? $0) }
    }
    #endif
}

nonisolated enum ImagePlaceholder {
    #if os(iOS)
    /// An image drawn once for light and once for dark mode; iOS shows the one that matches.
    static func adaptiveImage(size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        func render(_ style: UIUserInterfaceStyle) -> UIImage {
            var image = UIImage()
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                image = renderer.image { draw($0.cgContext) }
            }
            return image
        }
        let asset = UIImageAsset()
        asset.register(render(.light), with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(render(.dark), with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection.current)
    }

    static func chip(text: String, fontSize: CGFloat) -> UIImage {
        let font = UIFont.systemFont(ofSize: fontSize - 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let iconWidth: CGFloat = fontSize + 4
        let width = min(max(textSize.width + iconWidth + 26, 80), 360)
        let height = textSize.height + 10
        return adaptiveImage(size: CGSize(width: width, height: height)) { context in
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
            UIColor.secondarySystemBackground.setFill()
            path.fill()
            UIColor.separator.setStroke()
            path.lineWidth = 1
            path.stroke()
            let configuration = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
            if let icon = UIImage(systemName: "photo", withConfiguration: configuration)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
                icon.draw(in: CGRect(x: 9, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            }
            let textRect = CGRect(x: 9 + iconWidth + 6, y: (height - textSize.height) / 2,
                                  width: width - iconWidth - 26, height: textSize.height)
            var textAttrs = attrs
            textAttrs[.foregroundColor] = UIColor.secondaryLabel
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            textAttrs[.paragraphStyle] = paragraph
            (text as NSString).draw(in: textRect, withAttributes: textAttrs)
        }
    }
    #else
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
    #endif
}

/// Loads and caches images referenced from markdown (remote URLs or local paths).
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private var cache: [String: PlatformImage] = [:]
    private var failed: Set<String> = []

    private init() {}

    /// The image if it has already been loaded.
    func cachedImage(for source: String, baseURL: URL?) -> PlatformImage? {
        cache[cacheKey(source: source, baseURL: baseURL)]
    }

    func image(for source: String, baseURL: URL?) async -> PlatformImage? {
        let key = cacheKey(source: source, baseURL: baseURL)
        if let cached = cache[key] { return cached }
        if failed.contains(key) { return nil }
        guard let url = resolve(source, baseURL: baseURL) else {
            failed.insert(key)
            return nil
        }

        var image: PlatformImage? = nil
        if url.isFileURL {
            #if os(macOS)
            image = NSImage(contentsOf: url)
            #else
            image = UIImage(contentsOfFile: url.path)
            #endif
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            image = PlatformImage(data: data)
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
    let color: PlatformColor
    let size: CGFloat

    init(checked: Bool, color: PlatformColor, size: CGFloat) {
        self.checked = checked
        self.color = color
        self.size = size
        super.init(data: nil, ofType: nil)
        #if os(iOS)
        let side = size + 2
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let symbol = UIImage(systemName: checked ? "checkmark.square.fill" : "square", withConfiguration: configuration)
        image = ImagePlaceholder.adaptiveImage(size: CGSize(width: side, height: side)) { _ in
            guard let symbol else { return }
            symbol.withTintColor(color.resolvedColor(with: .current), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                                 width: symbol.size.width, height: symbol.size.height))
        }
        let font = UIFont.systemFont(ofSize: size)
        bounds = CGRect(x: 0, y: (font.capHeight - side) / 2 + 1, width: side, height: side)
        #else
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
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    #if os(iOS)
    /// The light or dark version, whichever the text view is showing.
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        image.map { $0.imageAsset?.image(with: .current) ?? $0 }
    }
    #endif
}
