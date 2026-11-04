//
//  FormattingToolbar.swift
//  Marky Mark
//
//  The formatting bar shown above the rendered editor.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FormattingToolbar: View {
    @Bindable var controller: RichEditorController
    let documentURL: URL?

    @State private var linkURL = ""
    @State private var linkText = ""
    @State private var imageAlt = ""
    @State private var imageSource = ""
    @State private var tableRows = 2
    @State private var tableColumns = 3

    private var state: FormatState { controller.state }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            toolbarRow
        }
        .background(.bar)
    }

    private var toolbarRow: some View {
        HStack(spacing: 2) {
            headingMenu
            separator

            ToolButton(symbol: "bold", help: "Bold (⌘B)", active: state.bold) { controller.toggleBold() }
            ToolButton(symbol: "italic", help: "Italic (⌘I)", active: state.italic) { controller.toggleItalic() }
            ToolButton(symbol: "strikethrough", help: "Strikethrough (⌘⇧X)", active: state.strike) { controller.toggleStrikethrough() }
            ToolButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Inline Code (⌘E)", active: state.code) { controller.toggleInlineCode() }
            separator

            ToolButton(symbol: "link", help: state.hasLink ? "Remove Link (⌘K)" : "Insert Link (⌘K)", active: state.hasLink) {
                controller.requestLink()
            }
            .popover(isPresented: $controller.showLinkPopover, arrowEdge: .bottom) { linkPopover }

            ToolButton(symbol: "photo", help: "Insert Image") { controller.requestImage() }
                .popover(isPresented: $controller.showImagePopover, arrowEdge: .bottom) { imagePopover }
            separator

            ToolButton(symbol: "list.bullet", help: "Bulleted List (⌘⇧8)", active: isKind(.bullet)) { controller.toggleBulletList() }
            ToolButton(symbol: "list.number", help: "Numbered List (⌘⇧7)", active: isKind(.ordered)) { controller.toggleOrderedList() }
            ToolButton(symbol: "checklist", help: "Task List (⌘⇧9)", active: isKind(.task(checked: false))) { controller.toggleTaskList() }
            separator

            ToolButton(symbol: "text.quote", help: "Blockquote (⌘⇧.)", active: isKind(.blockquote)) { controller.toggleBlockquote() }
            ToolButton(symbol: "curlybraces", help: "Code Block (⌘⇧C)", active: isKind(.codeBlock(language: ""))) { controller.toggleCodeBlock() }
            ToolButton(symbol: "text.bubble", help: "Comment (⌘⇧/) — kept in the file, left out of exports and counts", active: isKind(.comment)) { controller.toggleComment() }
            separator

            ToolButton(symbol: "minus", help: "Horizontal Rule") { controller.insertHorizontalRule() }
            ToolButton(symbol: "tablecells", help: "Insert Table") { controller.requestTable() }
                .popover(isPresented: $controller.showTablePopover, arrowEdge: .bottom) { tablePopover }
            separator

            ToolButton(symbol: "increase.indent", help: "Increase Indent (⌘])", disabled: !state.blockKind.isList) { controller.increaseIndent() }
            ToolButton(symbol: "decrease.indent", help: "Decrease Indent (⌘[)", disabled: !state.blockKind.isList || state.indent == 0) { controller.decreaseIndent() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var separator: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 4)
    }

    private func isKind(_ kind: BlockKind) -> Bool {
        state.blockKind.isSameFamily(as: kind)
    }

    // MARK: - Heading menu

    private var blockLabel: String {
        switch state.blockKind {
        case .paragraph: return "Paragraph"
        case .heading(let level): return "Heading \(level)"
        case .bullet: return "Bulleted List"
        case .ordered: return "Numbered List"
        case .task: return "Task List"
        case .blockquote: return "Quote"
        case .codeBlock: return "Code Block"
        case .horizontalRule: return "Rule"
        case .tableCell: return "Table Cell"
        case .comment: return "Comment"
        case .frontMatter: return "Metadata"
        }
    }

    private var headingMenu: some View {
        Menu {
            Button("Paragraph") { controller.setHeading(nil) }
            Divider()
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { controller.setHeading(level) }
            }
        } label: {
            Text(blockLabel)
                .frame(minWidth: 90, alignment: .leading)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(state.blockKind.isProtected)
        .help("Paragraph style")
    }

    // MARK: - Popovers

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Link").font(.headline)
            TextField("https://example.com", text: $linkURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commitLink)
            if !state.hasSelection {
                TextField("Link text (optional)", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit(commitLink)
            } else {
                Text("The selected text will become the link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { controller.showLinkPopover = false }
                    .keyboardShortcut(.cancelAction)
                Button("Insert", action: commitLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(linkURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func commitLink() {
        let url = linkURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        controller.showLinkPopover = false
        controller.insertLink(url: url, text: linkText)
        linkURL = ""
        linkText = ""
    }

    private var imagePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Image").font(.headline)
            HStack {
                TextField("URL or file path", text: $imageSource)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(commitImage)
                Button("Choose…", action: chooseImageFile)
            }
            TextField("Alt text (optional)", text: $imageAlt)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(commitImage)
            HStack {
                Spacer()
                Button("Cancel") { controller.showImagePopover = false }
                    .keyboardShortcut(.cancelAction)
                Button("Insert", action: commitImage)
                    .keyboardShortcut(.defaultAction)
                    .disabled(imageSource.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func chooseImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image"
        if panel.runModal() == .OK, let url = panel.url {
            imageSource = relativePath(for: url)
            if imageAlt.isEmpty {
                imageAlt = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    /// Paths inside the document's folder are stored relative to it.
    private func relativePath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let documentURL else { return path }
        let folder = documentURL.deletingLastPathComponent().standardizedFileURL.path
        if path.hasPrefix(folder + "/") {
            return String(path.dropFirst(folder.count + 1))
        }
        return path
    }

    private func commitImage() {
        let source = imageSource.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return }
        controller.showImagePopover = false
        controller.insertImage(alt: imageAlt, source: source)
        imageSource = ""
        imageAlt = ""
    }

    private var tablePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Table").font(.headline)
            Stepper("Rows: \(tableRows)", value: $tableRows, in: 1...50)
            Stepper("Columns: \(tableColumns)", value: $tableColumns, in: 1...12)
            Text("A header row is added automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { controller.showTablePopover = false }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    controller.showTablePopover = false
                    controller.insertTable(rows: tableRows, columns: tableColumns)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 240)
    }
}

// MARK: - Button

private struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : (disabled ? Color.secondary : Color.primary))
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(active ? Color.accentColor.opacity(0.18) : (hovering && !disabled ? Color.primary.opacity(0.08) : Color.clear))
        )
        .onHover { hovering = $0 }
        .disabled(disabled)
        .help(help)
    }
}
