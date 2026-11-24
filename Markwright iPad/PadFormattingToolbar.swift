//
//  PadFormattingToolbar.swift
//  Markwright iPad
//
//  The formatting strip above the editors. In the formatted pane it formats the text and shows
//  what's on at the cursor; in the raw pane it inserts Markdown syntax. On a phone-width screen
//  the same strip sits on top of the keyboard (PadKeyboardBar), with a button to put it away.
//

import SwiftUI

struct PadFormattingToolbar: View {
    let controller: PadEditorController
    var onPickPhoto: () -> Void = {}
    var onPickFile: () -> Void = {}
    /// Shown above the keyboard: bigger buttons for fingers, the keyboard's own background, and
    /// a button that hides the keyboard.
    var inKeyboard = false

    private var buttonSize: CGSize { inKeyboard ? CGSize(width: 40, height: 36) : CGSize(width: 34, height: 30) }

    private var state: FormatState? { controller.formattedIsActive ? controller.formatState : nil }

    private func blockIs(_ test: (BlockKind) -> Bool) -> Bool {
        guard let state else { return false }
        return test(state.blockKind)
    }

    var body: some View {
        if inKeyboard {
            HStack(spacing: 0) {
                strip
                Divider().frame(height: 24)
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 48, height: buttonSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Keyboard")
            }
            .clipShape(Capsule())
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        } else {
            strip.background(.bar)
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Menu {
                    Button("Paragraph") { controller.applyHeading(0) }
                    Divider()
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { controller.applyHeading(level) }
                    }
                } label: {
                    Label("Heading", systemImage: "textformat.size")
                        .labelStyle(.iconOnly)
                        .frame(width: buttonSize.width, height: buttonSize.height)
                        .background(highlight(blockIs { if case .heading = $0 { true } else { false } }))
                }
                .help("Heading")
                separator

                tool("bold", "Bold", on: controller.isOn(.mmBold)) { controller.applyInline(.mmBold) }
                tool("italic", "Italic", on: controller.isOn(.mmItalic)) { controller.applyInline(.mmItalic) }
                tool("strikethrough", "Strikethrough", on: controller.isOn(.mmStrike)) { controller.applyInline(.mmStrike) }
                tool("chevron.left.forwardslash.chevron.right", "Inline code", on: controller.isOn(.mmCode)) { controller.applyInline(.mmCode) }
                tool("highlighter", "Highlight", on: controller.isOn(.mmHighlight)) { controller.applyInline(.mmHighlight) }
                separator

                tool("link", "Link", on: state?.hasLink == true) { controller.requestLink() }
                tool("link.badge.plus", "Wiki link to another sheet") { controller.requestWikiLink() }
                tool("textformat.superscript", "Footnote") { controller.addFootnote() }
                Menu {
                    Button("Photo Library…", systemImage: "photo.on.rectangle", action: onPickPhoto)
                    Button("Choose File…", systemImage: "folder", action: onPickFile)
                    Divider()
                    Button("Image Link…", systemImage: "link") { controller.requestImageLink() }
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: buttonSize.width, height: buttonSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Image")
                .accessibilityLabel("Image")
                separator

                tool("list.bullet", "Bulleted list", on: blockIs { $0 == .bullet }) { controller.applyBulletList() }
                tool("list.number", "Numbered list", on: blockIs { $0 == .ordered }) { controller.applyNumberedList() }
                tool("checklist", "Task list", on: blockIs { if case .task = $0 { true } else { false } }) { controller.applyTaskList() }
                separator

                tool("text.quote", "Blockquote", on: blockIs { $0 == .blockquote }) { controller.applyQuote() }
                tool("curlybraces", "Code block", on: blockIs { if case .codeBlock = $0 { true } else { false } }) { controller.applyCodeBlock() }
                tool("text.bubble", "Comment", on: blockIs { $0 == .comment }) { controller.applyComment() }
                separator

                tool("minus", "Horizontal rule") { controller.addRule() }
                tool("tablecells", "Table") { controller.addTable() }
                if controller.formattedIsActive {
                    separator
                    tool("decrease.indent", "Outdent") { controller.indent(forward: false) }
                    tool("increase.indent", "Indent") { controller.indent(forward: true) }
                    tool(state?.folded == true ? "chevron.right.square" : "chevron.down.square",
                         state?.folded == true ? "Unfold section" : "Fold section",
                         on: state?.folded == true) { controller.toggleFold() }
                }
            }
            .padding(.horizontal, inKeyboard ? 6 : 10)
            .padding(.vertical, inKeyboard ? 4 : 6)
        }
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    private func highlight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.18) : .clear)
    }

    private func tool(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: buttonSize.width, height: buttonSize.height)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .background(highlight(on))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
