//
//  MarkdownPreview.swift
//  Marky Mark
//
//  Read-only rendered view of a Markdown document, styled from ThemeSettings.
//  Used by the iPad app beside the raw editor.
//

import SwiftUI

struct MarkdownPreview: View {
    let markdown: String
    var baseURL: URL? = nil
    /// Called with the index of a task item whose checkbox was tapped.
    var onToggleTask: ((Int) -> Void)? = nil
    private var theme = ThemeSettings.shared

    init(markdown: String, baseURL: URL? = nil, onToggleTask: ((Int) -> Void)? = nil) {
        self.markdown = markdown
        self.baseURL = baseURL
        self.onToggleTask = onToggleTask
    }

    private struct Item: Identifiable {
        let id: Int
        let block: MarkdownBlock
        let taskIndex: Int?
    }

    private var items: [Item] {
        var result: [Item] = []
        var tasks = 0
        for (index, block) in MarkdownParser.parse(markdown).enumerated() {
            var taskIndex: Int? = nil
            if case .taskListItem = block { taskIndex = tasks; tasks += 1 }
            result.append(Item(id: index, block: block, taskIndex: taskIndex))
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    blockView(item)
                }
                Spacer(minLength: 60)
            }
            .padding(24)
            .frame(maxWidth: theme.editorMaxWidth > 0 ? CGFloat(theme.editorMaxWidth) + 48 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.useCustomEditorColors ? theme.editorBackground : Color(platform: .mmBackground))
        .foregroundStyle(textColor)
    }

    // MARK: - Fonts & colors

    private var textColor: Color { theme.useCustomEditorColors ? theme.editorTextColor : .primary }
    private var bodySize: CGFloat { CGFloat(theme.bodyFontSize) }

    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch theme.editorFont {
        case "system", "": return .system(size: size, weight: weight)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        case "monospaced": return .system(size: size, weight: weight, design: .monospaced)
        default: return .custom(theme.editorFont, size: size).weight(weight)
        }
    }

    private var bodyFont: Font { font(size: bodySize) }
    private var lineSpacing: CGFloat { CGFloat(theme.lineSpacing) }

    private func headingFont(_ level: Int) -> Font {
        let scales: [CGFloat] = [2.0, 1.7, 1.4, 1.25, 1.1, 1.0]
        let weights: [Font.Weight] = [.bold, .bold, .semibold, .semibold, .medium, .medium]
        let index = min(max(level, 1), 6) - 1
        return font(size: bodySize * scales[index], weight: weights[index])
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ item: Item) -> some View {
        switch item.block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(inline(text, base: headingFont(level))).foregroundStyle(theme.headingColor)
                if theme.headingDividers && level <= 2 { Divider() }
            }
            .padding(.top, level <= 2 ? 12 : 8)
            .textSelection(.enabled)
        case .paragraph(let text):
            if let image = soleImage(text) {
                imageView(image)
            } else {
                Text(inline(text)).font(bodyFont).lineSpacing(lineSpacing).textSelection(.enabled)
            }
        case .unorderedListItem(let text, let indent):
            listRow(marker: Text("\u{2022}").foregroundStyle(.secondary), text: text, indent: indent)
        case .orderedListItem(let number, let text, let indent):
            listRow(marker: Text("\(number).").foregroundStyle(.secondary).monospacedDigit(), text: text, indent: indent)
        case .taskListItem(let checked, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    if let index = item.taskIndex { onToggleTask?(index) }
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? theme.taskCheckedColor : .secondary)
                        .font(bodyFont)
                }
                .buttonStyle(.plain)
                .disabled(onToggleTask == nil)
                Text(inline(text))
                    .font(bodyFont)
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? Color.secondary : textColor)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 20)
        case .codeBlock(_, let code):
            Text(code)
                .font(.system(size: bodySize - 1, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.codeBlockBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(platform: .mmSeparator), lineWidth: 0.5))
                .textSelection(.enabled)
                .padding(.vertical, 4)
        case .blockquote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(theme.blockquoteBarColor.opacity(0.7)).frame(width: 3)
                Text(inline(text.replacingOccurrences(of: "\n", with: "\n")))
                    .font(bodyFont)
                    .italic(theme.blockquoteItalic)
                    .foregroundStyle(.secondary)
                    .lineSpacing(lineSpacing)
                    .padding(.leading, 12)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        case .horizontalRule:
            Divider().padding(.vertical, 8)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .comment(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1).fill(Color(platform: .mmTertiaryLabel)).frame(width: 2)
                Text(text).font(bodyFont).italic().foregroundStyle(.secondary).padding(.leading, 12)
            }
            .padding(.vertical, 2)
        case .frontMatter, .blank:
            Spacer().frame(height: 6)
        }
    }

    private func listRow(marker: Text, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.font(bodyFont)
            Text(inline(text)).font(bodyFont).textSelection(.enabled)
        }
        .padding(.leading, CGFloat(indent) * 20)
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0, 1)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    Text(inline(column < headers.count ? headers[column] : ""))
                        .font(bodyFont.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.tableHeaderBackground)
                        .border(Color(platform: .mmSeparator), width: 0.5)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(inline(column < row.count ? row[column] : ""))
                            .font(bodyFont)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .border(Color(platform: .mmSeparator), width: 0.5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(platform: .mmSeparator), lineWidth: 0.5))
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    // MARK: - Images

    private func soleImage(_ text: String) -> (alt: String, source: String)? {
        let nodes = InlineParser.parse(text.trimmingCharacters(in: .whitespaces))
        guard nodes.count == 1, case .image(let alt, let source) = nodes[0] else { return nil }
        return (alt, source)
    }

    private func resolve(_ source: String) -> URL? {
        if let url = URL(string: source), url.scheme != nil { return url }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: source, relativeTo: baseURL.deletingLastPathComponent()).standardizedFileURL
    }

    @ViewBuilder
    private func imageView(_ image: (alt: String, source: String)) -> some View {
        if let url = resolve(image.source) {
            NaturalSizeImage(url: url) {
                imagePlaceholder(image.alt.isEmpty ? image.source : image.alt)
            }
        } else {
            imagePlaceholder(image.alt.isEmpty ? image.source : image.alt)
        }
    }

    private func imagePlaceholder(_ label: String) -> some View {
        Label(label, systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(platform: .mmSecondaryBackground)))
    }

    // MARK: - Inline

    private func inline(_ text: String, base: Font? = nil) -> AttributedString {
        var result = AttributedString()
        append(InlineParser.parse(text), to: &result, base: base ?? bodyFont, bold: false, italic: false, strike: false, link: nil)
        return result
    }

    private func append(_ nodes: [InlineNode], to result: inout AttributedString, base: Font,
                        bold: Bool, italic: Bool, strike: Bool, link: String?) {
        for node in nodes {
            switch node {
            case .text(let s):
                var piece = AttributedString(s)
                var f = base
                if bold { f = f.bold() }
                if italic { f = f.italic() }
                piece.font = f
                if strike {
                    piece.strikethroughStyle = .single
                    piece.foregroundColor = theme.strikethroughColor
                }
                if let link, let url = URL(string: link) {
                    piece.link = url
                    piece.foregroundColor = theme.linkColor
                    piece.underlineStyle = .single
                }
                result.append(piece)
            case .code(let s):
                var piece = AttributedString(s)
                piece.font = .system(size: bodySize, design: .monospaced)
                piece.backgroundColor = theme.inlineCodeBackground.opacity(0.5)
                result.append(piece)
            case .emphasis(let kids): append(kids, to: &result, base: base, bold: bold, italic: true, strike: strike, link: link)
            case .strong(let kids): append(kids, to: &result, base: base, bold: true, italic: italic, strike: strike, link: link)
            case .strike(let kids): append(kids, to: &result, base: base, bold: bold, italic: italic, strike: true, link: link)
            case .link(let label, let url): append(label, to: &result, base: base, bold: bold, italic: italic, strike: strike, link: url)
            case .image(let alt, let source):
                var piece = AttributedString("\u{1F5BC} " + (alt.isEmpty ? source : alt))
                piece.foregroundColor = theme.linkColor
                if let url = resolve(source) { piece.link = url }
                result.append(piece)
            }
        }
    }
}

// MARK: - Images at their natural size

#if canImport(AppKit)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// Shows an image no larger than its own pixel size, capped to the available width and a
/// maximum height, flush left. Loads once per URL and caches.
struct NaturalSizeImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: PlatformImage? = nil
    @State private var failed = false

    private static var cache: NSCache<NSURL, PlatformImage> { ImageCache.shared }

    var body: some View {
        Group {
            if let image {
                #if canImport(AppKit)
                let swiftUIImage = Image(nsImage: image)
                #else
                let swiftUIImage = Image(uiImage: image)
                #endif
                swiftUIImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: min(image.size.height, 480), alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if failed {
                placeholder()
            } else {
                ProgressView().frame(height: 60)
            }
        }
        .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            failed = false
            let loaded: PlatformImage?
            if url.isFileURL {
                loaded = PlatformImage(contentsOfFile: url.path)
            } else if let (data, _) = try? await URLSession.shared.data(from: url) {
                loaded = PlatformImage(data: data)
            } else {
                loaded = nil
            }
            if let loaded {
                Self.cache.setObject(loaded, forKey: url as NSURL)
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

@MainActor
private enum ImageCache {
    static let shared: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.countLimit = 60
        return cache
    }()
}
