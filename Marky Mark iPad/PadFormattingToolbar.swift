//
//  PadFormattingToolbar.swift
//  Marky Mark iPad
//
//  Buttons that insert Markdown markup into the raw editor.
//

import SwiftUI

struct PadFormattingToolbar: View {
    let controller: PadEditorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Menu {
                    Button("Paragraph") { controller.setHeading(0) }
                    Divider()
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { controller.setHeading(level) }
                    }
                } label: {
                    Label("Heading", systemImage: "textformat.size")
                        .labelStyle(.iconOnly)
                        .frame(width: 34, height: 30)
                }
                .help("Heading")
                separator

                tool("bold", "Bold") { controller.wrap(prefix: "**", suffix: "**", placeholder: "bold") }
                tool("italic", "Italic") { controller.wrap(prefix: "*", suffix: "*", placeholder: "italic") }
                tool("strikethrough", "Strikethrough") { controller.wrap(prefix: "~~", suffix: "~~", placeholder: "struck") }
                tool("chevron.left.forwardslash.chevron.right", "Inline code") { controller.wrap(prefix: "`", suffix: "`", placeholder: "code") }
                separator

                tool("link", "Link") { controller.wrap(prefix: "[", suffix: "](https://)", placeholder: "link text") }
                tool("photo", "Image") { controller.insertBlock("![alt text](image.png)", selectingPlaceholder: "image.png") }
                separator

                tool("list.bullet", "Bulleted list") { controller.togglePrefix("- ", alternatives: ["* ", "+ ", "- [ ] ", "- [x] ", "1. "]) }
                tool("list.number", "Numbered list") { controller.toggleNumberedList() }
                tool("checklist", "Task list") { controller.togglePrefix("- [ ] ", alternatives: ["- [x] ", "- ", "* ", "+ ", "1. "]) }
                separator

                tool("text.quote", "Blockquote") { controller.togglePrefix("> ") }
                tool("curlybraces", "Code block") { controller.insertBlock("```\ncode\n```", selectingPlaceholder: "code") }
                tool("text.bubble", "Comment") { controller.insertBlock("<!-- note -->", selectingPlaceholder: "note") }
                separator

                tool("minus", "Horizontal rule") { controller.insertBlock("---") }
                tool("tablecells", "Table") {
                    controller.insertBlock("| Header 1 | Header 2 |\n| --- | --- |\n| Cell | Cell |", selectingPlaceholder: "Header 1")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
