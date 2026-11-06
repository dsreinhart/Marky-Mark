//
//  PadDocumentView.swift
//  Markwright iPad
//
//  One document: raw editor with formatting toolbar, live preview, dashboard.
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct PadDocumentView: View {
    @Binding var document: MarkdownFileDocument
    let fileURL: URL?

    enum Layout: String, CaseIterable {
        case editor, split, preview
    }

    @State private var controller = PadEditorController()
    @AppStorage("pad.layout") private var layoutRaw = Layout.split.rawValue
    @AppStorage("view.typewriter") private var typewriter = false
    @AppStorage("view.showDashboard") private var showDashboard = false
    @State private var showSettings = false
    @State private var showCheatSheet = false
    @State private var showHelp = false
    @State private var showExportPreview = false
    @State private var shareFile: ShareFile? = nil
    @State private var errorMessage: String? = nil
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFilePicker = false
    @State private var pendingImage: PadImageStore.Prepared? = nil
    @State private var showFolderAccessPrompt = false
    @State private var showFolderPicker = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var linkedSheet: LinkedSheet? = nil
    @Environment(\.dismiss) private var dismissDocument
    private var theme = ThemeSettings.shared

    init(document: Binding<MarkdownFileDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
    }

    private var layout: Layout {
        get { Layout(rawValue: layoutRaw) ?? .split }
    }

    /// Split view needs room; in a compact width fall back to the editor.
    private var effectiveLayout: Layout {
        sizeClass == .compact && layout == .split ? .editor : layout
    }

    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    private var goalKey: String {
        fileURL?.standardizedFileURL.path ?? "untitled"
    }

    var body: some View {
        VStack(spacing: 0) {
            if effectiveLayout != .preview {
                PadFormattingToolbar(controller: controller,
                                     onPickPhoto: { showPhotoPicker = true },
                                     onPickFile: { showFilePicker = true })
                Divider()
            }
            HStack(spacing: 0) {
                if effectiveLayout != .preview {
                    editor
                }
                if effectiveLayout == .split {
                    Divider()
                }
                if effectiveLayout != .editor {
                    MarkdownPreview(markdown: document.text, baseURL: fileURL) { index in
                        controller.toggleTask(index)
                    }
                }
            }
            Divider()
            statusBar
        }
        .inspector(isPresented: $showDashboard) {
            DashboardView(text: $document.text, goalKey: goalKey, fileURL: fileURL,
                          onJumpToHeading: { controller.jumpToHeading($0) },
                          onOpenWikiLink: { target in Task { await openWikiLink(target) } },
                          onJumpToTag: { tag in controller.jump(toText: "#" + tag) })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar { toolbarContent }
        .environment(\.openURL, OpenURLAction { url in
            guard let target = WikiLink.target(from: url) else { return .systemAction }
            Task { await openWikiLink(target) }
            return .handled
        })
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showCheatSheet) { MarkdownCheatSheet() }
        .sheet(isPresented: $showHelp) { PadHelpView() }
        .sheet(isPresented: $showExportPreview) { PadExportPreviewView(markdown: document.text, title: title, documentURL: fileURL) }
        .sheet(item: $shareFile) { file in ActivityView(items: [file.url]) }
        .sheet(item: $linkedSheet) { sheet in LinkedSheetView(sheet: sheet) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await insertPickedPhoto(item) }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): insertPickedFile(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Save the image next to this document?", isPresented: $showFolderAccessPrompt) {
            Button("Choose Folder…") { showFolderPicker = true }
            Button("Embed in Text Instead") { finishPendingImage(allowEmbed: true) }
            Button("Cancel", role: .cancel) { pendingImage = nil }
        } message: {
            Text("Markwright can only write inside folders you've opened. Open this document's folder once and images will be saved beside it as files. Otherwise the image is embedded in the Markdown.")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(startingAt: fileURL?.deletingLastPathComponent()) { folder in
                showFolderPicker = false
                if let folder { PadFolderAccess.grant(folder) }
                finishPendingImage(allowEmbed: folder == nil)
            }
        }
        .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var editor: some View {
        PadEditorView(
            text: $document.text,
            fontSize: CGFloat(theme.bodyFontSize),
            textColor: theme.useCustomEditorColors ? UIColor(theme.editorTextColor) : .label,
            background: theme.useCustomEditorColors ? UIColor(theme.editorBackground) : nil,
            maxWidth: CGFloat(theme.editorMaxWidth),
            typewriter: typewriter,
            controller: controller
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Layout", selection: $layoutRaw) {
                Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right").tag(Layout.editor.rawValue)
                if sizeClass != .compact {
                    Label("Split", systemImage: "rectangle.split.2x1").tag(Layout.split.rawValue)
                }
                Label("Preview", systemImage: "doc.richtext").tag(Layout.preview.rawValue)
            }
            .pickerStyle(.segmented)

            Button {
                showDashboard.toggle()
            } label: {
                Label("Dashboard", systemImage: "sidebar.right")
            }

            Menu {
                Toggle("Typewriter Scrolling", isOn: $typewriter)
                Divider()
                Button("Export Preview…", systemImage: "doc.text.magnifyingglass") { showExportPreview = true }
                Button("Share HTML…", systemImage: "square.and.arrow.up") { share { try PadExporter.htmlFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Share PDF…", systemImage: "square.and.arrow.up") { share { try PadExporter.pdfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Share RTF…", systemImage: "square.and.arrow.up") { share { try PadExporter.rtfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Print…", systemImage: "printer") {
                    PadExporter.print(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL, from: PadExporter.keyWindowView)
                }
                Divider()
                Button("Recent Files…", systemImage: "clock") { dismissDocument() }
                Button("Markwright Help", systemImage: "questionmark.circle") { showHelp = true }
                Button("Markdown Cheat Sheet", systemImage: "list.bullet.rectangle") { showCheatSheet = true }
                Button("Settings…", systemImage: "gearshape") { showSettings = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var statusBar: some View {
        let stats = TextStatistics.compute(markdown: document.text)
        let goal = GoalStore.shared.goal(for: goalKey)
        return HStack(spacing: 10) {
            if typewriter {
                Text("Typewriter").foregroundStyle(.tertiary)
            }
            Spacer()
            if let goal {
                let current = goal.current(from: stats)
                ProgressView(value: goal.fraction(current: current))
                    .frame(width: 70)
                    .tint(goal.isMet(current: current) ? .green : .accentColor)
                Text("\(current.formatted()) / \(goal.target.formatted()) \(goal.kind.label.lowercased())")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("\(stats.words.formatted()) words").foregroundStyle(.secondary).monospacedDigit()
            Text("\(stats.characters.formatted()) chars").foregroundStyle(.tertiary).monospacedDigit()
            if stats.readingMinutes > 0 {
                Text("\(stats.readingMinutes) min read").foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func share(_ make: () throws -> URL) {
        do { shareFile = ShareFile(url: try make()) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Wiki links

    /// Shows `[[target]]` from the document's folder, creating the file when missing. iPadOS has no
    /// way to open another document in this window, so it appears as a sheet with an Open in Files button.
    private func openWikiLink(_ target: String) async {
        guard let folder = fileURL?.deletingLastPathComponent() else {
            errorMessage = "Save this document first so links can be resolved next to it."
            return
        }
        PadFolderAccess.begin(folder)
        let candidates = ["md", "markdown", "txt"].map { folder.appending(path: target + "." + $0) }
        var url = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        if url == nil {
            let created = folder.appending(path: target.replacingOccurrences(of: "/", with: "-") + ".md")
            do {
                try ("# " + target + "\n\n").write(to: created, atomically: true, encoding: .utf8)
                url = created
            } catch {
                errorMessage = "No sheet named \u{201C}\(target)\u{201D} here, and the folder isn't writable. Open the folder once via the image button's prompt, or create the sheet in Files."
                return
            }
        }
        guard let url else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        linkedSheet = LinkedSheet(url: url, text: text)
    }

    // MARK: - Images
    // MARK: - Images

    private func insertPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Could not load that photo."
            return
        }
        let type = item.supportedContentTypes.first
        insertImage(data: data, name: item.itemIdentifier.map { _ in "photo" }, type: type)
    }

    private func insertPickedFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read that file."
            return
        }
        insertImage(data: data, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
    }

    private func insertImage(data: Data, name: String?, type: UTType?) {
        guard let prepared = PadImageStore.prepare(data: data, suggestedName: name, type: type) else {
            errorMessage = "That file isn't an image."
            return
        }
        if let stored = PadImageStore.storeBeside(prepared, documentURL: fileURL) {
            insert(stored)
        } else if fileURL != nil {
            pendingImage = prepared
            showFolderAccessPrompt = true
        } else {
            insert(PadImageStore.embed(prepared))
        }
    }

    /// After the folder prompt: try the folder again, else embed if the user agreed.
    private func finishPendingImage(allowEmbed: Bool) {
        guard let prepared = pendingImage else { return }
        pendingImage = nil
        if let stored = PadImageStore.storeBeside(prepared, documentURL: fileURL) {
            insert(stored)
        } else if allowEmbed {
            insert(PadImageStore.embed(prepared))
        } else {
            errorMessage = "Couldn't write to that folder. The image was not added."
        }
    }

    private func insert(_ stored: PadImageStore.Stored) {
        controller.insertBlock("![\(stored.alt)](\(stored.source))")
    }
}


/// The user guide bundled with the app, read in a sheet over the document.
struct PadHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private var guide: String {
        guard let url = Bundle.main.url(forResource: "Markwright Help", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The guide is missing from this copy of Markwright."
        }
        return text
    }

    var body: some View {
        NavigationStack {
            MarkdownPreview(markdown: guide)
                .navigationTitle("Markwright Help")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationSizing(.page)
    }
}

/// A sheet reached through a wiki link: preview plus a way into Files, where tapping opens it for editing.
struct LinkedSheet: Identifiable {
    let url: URL
    let text: String
    var id: String { url.path }
}

struct LinkedSheetView: View {
    let sheet: LinkedSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MarkdownPreview(markdown: sheet.text, baseURL: sheet.url)
                .navigationTitle(sheet.url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open in Files", systemImage: "folder") {
                            if let files = URL(string: "shareddocuments://" + sheet.url.path) {
                                UIApplication.shared.open(files)
                            }
                        }
                    }
                }
        }
    }
}
