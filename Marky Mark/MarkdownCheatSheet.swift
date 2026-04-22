//
//  MarkdownCheatSheet.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI

/// A popup window displaying all supported Markdown syntax with examples.
struct MarkdownCheatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "number.square")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Markdown Cheat Sheet")
                    .font(.title2.bold())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(CheatSheetSection.all) { section in
                        sectionView(section)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 600, height: 650)
    }

    private func sectionView(_ section: CheatSheetSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(.tint)

            ForEach(section.items) { item in
                HStack(alignment: .top, spacing: 16) {
                    Text(item.syntax)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 260, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.controlBackgroundColor))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(item.result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if section.id != CheatSheetSection.all.last?.id {
                Divider()
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Data model

struct CheatSheetItem: Identifiable {
    let id = UUID()
    let syntax: String
    let description: String
    let result: String
}

struct CheatSheetSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [CheatSheetItem]

    static let all: [CheatSheetSection] = [
        CheatSheetSection(title: "Headings", items: [
            CheatSheetItem(syntax: "# Heading 1", description: "Largest heading", result: "Creates an H1 heading"),
            CheatSheetItem(syntax: "## Heading 2", description: "Second-level heading", result: "Creates an H2 heading"),
            CheatSheetItem(syntax: "### Heading 3", description: "Third-level heading", result: "Creates an H3 heading"),
            CheatSheetItem(syntax: "###### Heading 6", description: "Smallest heading", result: "Supports H1 through H6"),
        ]),
        CheatSheetSection(title: "Text Formatting", items: [
            CheatSheetItem(syntax: "**bold text**", description: "Bold", result: "Makes text bold"),
            CheatSheetItem(syntax: "*italic text*", description: "Italic", result: "Makes text italic"),
            CheatSheetItem(syntax: "***bold & italic***", description: "Bold + Italic", result: "Makes text bold and italic"),
            CheatSheetItem(syntax: "~~struck text~~", description: "Strikethrough", result: "Draws a line through text"),
        ]),
        CheatSheetSection(title: "Code", items: [
            CheatSheetItem(syntax: "`inline code`", description: "Inline code", result: "Monospaced inline snippet"),
            CheatSheetItem(syntax: "```lang\ncode here\n```", description: "Code block", result: "Fenced multi-line code block"),
        ]),
        CheatSheetSection(title: "Lists", items: [
            CheatSheetItem(syntax: "- Item", description: "Unordered list", result: "Bullet point (also * or +)"),
            CheatSheetItem(syntax: "1. Item", description: "Ordered list", result: "Numbered list item"),
            CheatSheetItem(syntax: "  - Sub-item", description: "Nested list", result: "Indent 2 spaces to nest"),
            CheatSheetItem(syntax: "- [ ] Task", description: "Unchecked task", result: "Task list (unchecked)"),
            CheatSheetItem(syntax: "- [x] Done", description: "Checked task", result: "Task list (checked)"),
        ]),
        CheatSheetSection(title: "Links & Images", items: [
            CheatSheetItem(syntax: "[text](https://url)", description: "Hyperlink", result: "Clickable link with label"),
            CheatSheetItem(syntax: "![alt](https://url)", description: "Image", result: "Embedded image reference"),
        ]),
        CheatSheetSection(title: "Blockquotes", items: [
            CheatSheetItem(syntax: "> Quoted text", description: "Blockquote", result: "Indented quote with accent bar"),
            CheatSheetItem(syntax: "> Line 1\n> Line 2", description: "Multi-line quote", result: "Consecutive > lines merge"),
        ]),
        CheatSheetSection(title: "Horizontal Rule", items: [
            CheatSheetItem(syntax: "---", description: "Horizontal rule", result: "Also *** or ___"),
        ]),
        CheatSheetSection(title: "Tables", items: [
            CheatSheetItem(syntax: "| H1 | H2 |\n|---|---|\n| A | B |", description: "Table", result: "Pipe-delimited columns"),
        ]),
    ]
}

#Preview {
    MarkdownCheatSheet()
}
