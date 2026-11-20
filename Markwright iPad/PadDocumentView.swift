//
//  PadDocumentView.swift
//  Markwright iPad
//
//  One document: the Raw (Markdown source) and Formatted editors, alone or side by side
//  (Dual), with the formatting toolbar, the dashboard and the More menu.
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct PadDocumentView: View {
    @Binding var document: MarkdownFileDocument
    let fileURL: URL?

    /// Raw, Dual and Formatted, as on the Mac. The stored names are the ones from before the
    /// formatted view could be edited (Editor, Split, Preview), so a saved choice carries over.
    enum Layout: String, CaseIterable {
        case editor, split, preview
    }

    @State private var controller = PadEditorController()
    @AppStorage("pad.layout") private var layoutRaw = Layout.split.rawValue
    @AppStorage("view.typewriter") private var typewriter = false
    @AppStorage("view.focusMode") private var focusRaw = FocusMode.off.rawValue
    @AppStorage("view.showDashboard") private var showDashboard = false
    @State private var showSettings = false
    @State private var showCheatSheet = false
    @State private var showHelp = false
    @State private var showExportPreview = false
    @State private var shareFile: ShareFile? = nil
    @State private var errorMessage: String? = nil
    @State private var errorTitle = "Export Failed"
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFilePicker = false
    @State private var pendingImage: PadImageStore.Prepared? = nil
    @State private var showFolderAccessPrompt = false
    @State private var showFolderPicker = false
    /// What's typed in the formatted editor's link prompt.
    @State private var promptAddress = ""
    @State private var promptLabel = ""
    /// Name of a folder just allowed that doesn't hold this document.
    @State private var wrongFolder: String? = nil
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

    /// Dual needs room; in a compact width fall back to Raw.
    private var effectiveLayout: Layout {
        sizeClass == .compact && layout == .split ? .editor : layout
    }

    private var focusMode: FocusMode { FocusMode(rawValue: focusRaw) ?? .off }

    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    private var goalKey: String {
        fileURL?.standardizedFileURL.path ?? "untitled"
    }

    var body: some View {
        VStack(spacing: 0) {
            PadFormattingToolbar(controller: controller,
                                 onPickPhoto: { showPhotoPicker = true },
                                 onPickFile: { showFilePicker = true })
            Divider()
            HStack(spacing: 0) {
                if effectiveLayout != .preview {
                    editor
                }
                if effectiveLayout == .split {
                    Divider()
                }
                if effectiveLayout != .editor {
                    formatted
                }
            }
            Divider()
            statusBar
        }
        .onChange(of: effectiveLayout, initial: true) { _, layout in
            controller.setPanes(raw: layout != .preview, formatted: layout != .editor)
        }
        .onAppear {
            controller.openWikiLink = { target in Task { await openWikiLink(target) } }
            controller.pasteImage = { data, type in insertImage(data: data, name: "pasted", type: type) }
        }
        .inspector(isPresented: $showDashboard) {
            DashboardView(text: $document.text, goalKey: goalKey, fileURL: fileURL,
                          onJumpToHeading: { controller.goToHeading($0) },
                          onOpenWikiLink: { target in Task { await openWikiLink(target) } },
                          onJumpToTag: { tag in controller.goToText("#" + tag) })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar { toolbarContent }
        .onChange(of: fileURL, initial: true) { _, url in
            guard let url else { return }
            // Images beside the document need its folder's saved grant after a relaunch.
            PadFolderAccess.begin(url.deletingLastPathComponent())
            // After a rename (here or in Files), bring its pictures into "<New name>-images".
            if let moved = PadImageStore.adoptPictures(text: document.text, documentURL: url) {
                document.text = moved
            }
        }
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
            case .failure(let error): showError("Image Not Added", error.localizedDescription)
            }
        }
        .alert("Allow Access to \(documentFolderName)?", isPresented: $showFolderAccessPrompt) {
            Button("Allow Access\u{2026}") { showFolderPicker = true }
            Button("Embed in Text Instead") { embedPendingImage() }
            Button("Cancel", role: .cancel) { pendingImage = nil }
        } message: {
            Text("iPadOS lets Markwright save images beside a document only after you allow its folder once. In the window that opens, check that it shows \(documentFolderName), then tap Open. Folders inside it are covered too.")
        }
        .alert("Allow \(documentFolderName) Instead?", isPresented: Binding(get: { wrongFolder != nil }, set: { if !$0 { wrongFolder = nil } })) {
            Button("Allow Access\u{2026}") {
                wrongFolder = nil
                showFolderPicker = true
            }
            Button("Cancel", role: .cancel) {
                wrongFolder = nil
                pendingImage = nil
            }
        } message: {
            Text("The folder allowed was \u{201C}\(wrongFolder ?? "")\u{201D}, but this document is in \(documentFolderName). Allow \(documentFolderName), or a folder that contains it, and the image will be saved there.")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(startingAt: fileURL?.deletingLastPathComponent()) { folder in
                showFolderPicker = false
                finishPendingImage(pickedFolder: folder)
            }
        }
        .alert(controller.prompt?.title ?? "", isPresented: Binding(get: { controller.prompt != nil }, set: { shown in
            if !shown { DispatchQueue.main.async { controller.prompt = nil } }
        }), presenting: controller.prompt) { prompt in
            promptFields(prompt)
        } message: { prompt in
            switch prompt.kind {
            case .wikiLink: Text("The name of a sheet in this document's folder.")
            case .image: Text("The address of a picture on the web.")
            case .link: EmptyView()
            }
        }
        .onChange(of: controller.prompt?.id) {
            promptAddress = controller.prompt?.address ?? ""
            promptLabel = ""
        }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
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
            // In Dual, Focus follows the cursor, which is only in one pane.
            focus: controller.isDual && controller.activePane != .raw ? .off : focusMode,
            controller: controller,
            sync: controller.dualSync
        )
    }

    private var formatted: some View {
        PadRichEditorView(
            text: $document.text,
            style: EditorStyle(theme: theme),
            baseURL: fileURL,
            typewriter: typewriter,
            focus: focusMode,
            controller: controller,
            sync: controller.dualSync
        )
    }

    /// The fields and buttons of the formatted editor's link prompt.
    @ViewBuilder
    private func promptFields(_ prompt: PadLinkPrompt) -> some View {
        switch prompt.kind {
        case .link:
            TextField("https://", text: $promptAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if prompt.needsLabel {
                TextField("Text to show", text: $promptLabel)
            }
        case .wikiLink:
            TextField("Sheet name", text: $promptAddress)
        case .image:
            TextField("https://", text: $promptAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Button(prompt.canRemove ? "Update" : "Add") {
            controller.finishPrompt(prompt, address: promptAddress, label: promptLabel)
        }
        if prompt.canRemove {
            Button("Remove Link", role: .destructive) { controller.removeLink(prompt) }
        }
        Button("Cancel", role: .cancel) {}
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Layout", selection: Binding(get: { layoutRaw }, set: { value in
                controller.layoutWillChange()
                layoutRaw = value
            })) {
                Label("Raw", systemImage: "chevron.left.forwardslash.chevron.right").tag(Layout.editor.rawValue)
                if sizeClass != .compact {
                    Label("Dual", systemImage: "rectangle.split.2x1").tag(Layout.split.rawValue)
                }
                Label("Formatted", systemImage: "doc.richtext").tag(Layout.preview.rawValue)
            }
            .pickerStyle(.segmented)

            Button {
                showDashboard.toggle()
            } label: {
                Label("Dashboard", systemImage: "sidebar.right")
            }

            Menu {
                Toggle("Typewriter Scrolling", isOn: $typewriter)
                Picker("Focus", systemImage: "scope", selection: $focusRaw) {
                    ForEach(FocusMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                Divider()
                Button("Export Preview…", systemImage: "doc.text.magnifyingglass") { showExportPreview = true }
                Button("Share HTML…", systemImage: "square.and.arrow.up") { share { try PadExporter.htmlFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Share PDF…", systemImage: "square.and.arrow.up") { shareLater { try await PadExporter.pdfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Share RTF…", systemImage: "square.and.arrow.up") { share { try PadExporter.rtfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Print…", systemImage: "printer") {
                    Task {
                        do { try await PadExporter.print(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL, from: PadExporter.keyWindowView) }
                        catch { showError("Print Failed", error.localizedDescription) }
                    }
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
            if focusMode != .off {
                Text("Focus: \(focusMode.label)").foregroundStyle(.tertiary)
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
        do { shareFile = ShareFile(url: try make()) } catch { showError("Export Failed", error.localizedDescription) }
    }

    private func shareLater(_ make: @escaping () async throws -> URL) {
        Task {
            do { shareFile = ShareFile(url: try await make()) } catch { showError("Export Failed", error.localizedDescription) }
        }
    }

    // MARK: - Wiki links

    /// Shows `[[target]]` from the document's folder, creating the file when missing. iPadOS has no
    /// way to open another document in this window, so it appears as a sheet with an Open in Files button.
    private func openWikiLink(_ target: String) async {
        guard let folder = fileURL?.deletingLastPathComponent() else {
            showError("Link Not Opened", "Save this document first so links can be resolved next to it.")
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
                showError("Link Not Opened", "No sheet named \u{201C}\(target)\u{201D} here, and the folder isn't writable. Open the folder once via the image button's prompt, or create the sheet in Files.")
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
            showError("Image Not Added", "Could not load that photo.")
            return
        }
        let type = item.supportedContentTypes.first
        insertImage(data: data, name: item.itemIdentifier.map { _ in "photo" }, type: type)
    }

    private func insertPickedFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            showError("Image Not Added", "Could not read that file.")
            return
        }
        insertImage(data: data, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
    }

    private func insertImage(data: Data, name: String?, type: UTType?) {
        guard let prepared = PadImageStore.prepare(data: data, suggestedName: name, type: type) else {
            showError("Image Not Added", "That file isn't an image.")
            return
        }
        guard let fileURL else {
            insert(PadImageStore.embed(prepared))
            return
        }
        if let stored = try? PadImageStore.storeBeside(prepared, documentURL: fileURL, text: document.text) {
            insert(stored)
        } else {
            pendingImage = prepared
            showFolderAccessPrompt = true
        }
    }

    /// After the folder window: save into the document's folder, or explain and offer the window
    /// again when a different folder was allowed. Cancelling adds nothing.
    private func finishPendingImage(pickedFolder: URL?) {
        guard let prepared = pendingImage else { return }
        guard let picked = pickedFolder, let fileURL else {
            pendingImage = nil
            return
        }
        let folder = fileURL.deletingLastPathComponent()
        PadDiagnostics.log("folder window returned \(picked.path) for document folder \(folder.path)")
        if PadFolderAccess.grant(picked) == .refused {
            pendingImage = nil
            showError("Image Not Added", "iPadOS didn't give Markwright access to \u{201C}\(picked.lastPathComponent)\u{201D}. Try again, or embed the image instead.")
            return
        }
        guard PadFolderAccess.grant(picked, covers: folder) else {
            wrongFolder = picked.lastPathComponent   // keeps pendingImage for another try
            return
        }
        pendingImage = nil
        do {
            insert(try PadImageStore.storeBeside(prepared, documentURL: fileURL, text: document.text))
        } catch {
            showError("Image Not Added", "Couldn't save it in \(documentFolderName): \(error.localizedDescription)")
        }
    }

    private var documentFolderName: String {
        "\u{201C}\(fileURL?.deletingLastPathComponent().lastPathComponent ?? "this folder")\u{201D}"
    }

    private func embedPendingImage() {
        guard let prepared = pendingImage else { return }
        pendingImage = nil
        insert(PadImageStore.embed(prepared))
    }

    private func showError(_ title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    private func insert(_ stored: PadImageStore.Stored) {
        controller.addImage(alt: stored.alt, source: stored.source)
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
        return HelpGuide.adaptedForPad(text)
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
