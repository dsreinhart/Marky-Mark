//
//  MarkdownPreviewView.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI

/// Renders parsed Markdown blocks as beautifully styled SwiftUI views.
struct MarkdownPreviewView: View {
    let blocks: [MarkdownBlock]
    @Binding var scrollFraction: CGFloat
    var theme = ThemeSettings.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        blockView(for: block)
                            .id(index)
                    }
                    Spacer(minLength: 40)
                }
                .padding(20)
            }
            .onChange(of: scrollFraction) { _, newValue in
                let targetIndex = Int(newValue * CGFloat(max(blocks.count - 1, 1)))
                let clamped = min(max(targetIndex, 0), blocks.count - 1)
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(clamped, anchor: .top)
                }
            }
        }
    }

    private var bodyFont: Font {
        .system(size: theme.bodyFontSize)
    }

    @ViewBuilder
    private func blockView(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            Text(MarkdownParser.styledText(text, theme: theme))
                .font(bodyFont)
                .lineSpacing(4)
                .textSelection(.enabled)
        case .unorderedListItem(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2022}")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                Text(MarkdownParser.styledText(text, theme: theme))
                    .font(bodyFont)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 20)
        case .orderedListItem(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(MarkdownParser.styledText(text, theme: theme))
                    .font(bodyFont)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 20)
        case .taskListItem(let checked, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? theme.taskCheckedColor : .secondary)
                    .font(bodyFont)
                Text(MarkdownParser.styledText(text, theme: theme))
                    .font(bodyFont)
                    .textSelection(.enabled)
                    .if(checked) { view in
                        view.strikethrough(color: .secondary)
                    }
            }
            .padding(.leading, CGFloat(indent) * 20)
        case .codeBlock(_, let code):
            codeBlockView(code: code)
        case .blockquote(let text):
            blockquoteView(text: text)
        case .horizontalRule:
            Divider()
                .padding(.vertical, 8)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .blank:
            Spacer()
                .frame(height: 8)
        }
    }

    // MARK: - Heading

    private func headingView(level: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MarkdownParser.styledText(text, theme: theme))
                .font(fontForHeading(level))
                .fontWeight(.bold)
                .foregroundStyle(theme.headingColor)
                .textSelection(.enabled)
            if theme.headingDividers && level <= 2 {
                Divider()
            }
        }
        .padding(.top, level <= 2 ? 12 : 8)
        .padding(.bottom, 2)
    }

    private func fontForHeading(_ level: Int) -> Font {
        let base = theme.bodyFontSize
        switch level {
        case 1: return .system(size: base * 2.0, weight: .bold, design: .default)
        case 2: return .system(size: base * 1.7, weight: .bold, design: .default)
        case 3: return .system(size: base * 1.4, weight: .semibold, design: .default)
        case 4: return .system(size: base * 1.25, weight: .semibold, design: .default)
        case 5: return .system(size: base * 1.1, weight: .medium, design: .default)
        default: return .system(size: base, weight: .medium, design: .default)
        }
    }

    // MARK: - Code block

    private func codeBlockView(code: String) -> some View {
        Text(code)
            .font(.system(size: theme.bodyFontSize - 1, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.codeBlockBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.separatorColor), lineWidth: 0.5)
            )
            .textSelection(.enabled)
            .padding(.vertical, 4)
    }

    // MARK: - Blockquote

    private func blockquoteView(text: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.blockquoteBarColor.opacity(0.6))
                .frame(width: 4)
            Text(MarkdownParser.styledText(text, theme: theme))
                .font(bodyFont)
                .if(theme.blockquoteItalic) { $0.italic() }
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .padding(.leading, 12)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Table

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    Text(MarkdownParser.styledText(header, theme: theme))
                        .font(bodyFont.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    if index < headers.count - 1 {
                        Divider()
                    }
                }
            }
            .background(theme.tableHeaderBackground)

            Divider()

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        Text(MarkdownParser.styledText(cell, theme: theme))
                            .font(bodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        if colIndex < row.count - 1 {
                            Divider()
                        }
                    }
                }
                if rowIndex < rows.count - 1 {
                    Divider()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(.separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}
