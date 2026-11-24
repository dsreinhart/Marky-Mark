//
//  PadDocumentView.swift
//  Markwright iPad
//
//  One document: the Raw (Markdown source) and Formatted editors, alone or side by side
//  (Dual), with the formatting toolbar, the dashboard and the More menu. At a compact width
//  (iPhone, or a narrow iPad window) there is no Dual, the formatting toolbar rides on the
//  keyboard, the status line steps aside while typing and the dashboard is in More.
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct PadDocumentView: View {
    @Bindable var document: Document
    @Binding var isComposing: Bool
    /// Shows another file in this window (a wiki link).
    let onOpenFile: (URL) -> Void
    let onQuickOpen: () -> Void
    /// Whether the sheet shows a Library button: on iPad while the library is hidden (to bring it
    /// back), on a wide iPhone always (to show and hide it; the system's own button is removed there).
    var showsLibraryButton = false
    var onToggleLibrary: () -> Void = {}
    private var fileURL: URL? { document.fileURL }

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
    @Environment(\.scenePhase) private var scenePhase
    /// The other text when this file changed elsewhere while being edited here.
    @State private var conflictText: String? = nil
    /// A `[[wiki link]]` to a sheet that doesn't exist yet.
    @State private var missingLink: String? = nil
    /// The formatting toolbar as the editors' keyboard accessory, at a compact width.
    @State private var keyboardBar: PadKeyboardBar? = nil
    @State private var keyboardShown = false
    /// The dashboard as a sheet on a phone; not remembered, so it doesn't open with every sheet.
    @State private var showDashboardSheet = false
    private var theme = ThemeSettings.shared

    init(document: Document, isComposing: Binding<Bool>, onOpenFile: @escaping (URL) -> Void, onQuickOpen: @escaping () -> Void,
         showsLibraryButton: Bool = false, onToggleLibrary: @escaping () -> Void = {}) {
        self.document = document
        _isComposing = isComposing
        self.onOpenFile = onOpenFile
        self.onQuickOpen = onQuickOpen
        self.showsLibraryButton = showsLibraryButton
        self.onToggleLibrary = onToggleLibrary
    }

    private var layout: Layout {
        get { Layout(rawValue: layoutRaw) ?? .split }
    }

    private var isCompact: Bool { sizeClass == .compact }

    /// Dual needs room; in a compact width it shows Formatted.
    private var effectiveLayout: Layout {
        isCompact && layout == .split ? .preview : layout
    }

    /// The bar above the keyboard, when the toolbar isn't shown under the title.
    private var keyboardAccessory: UIView? {
        isCompact && !isComposing ? keyboardBar?.view : nil
    }

    private var focusMode: FocusMode { FocusMode(rawValue: focusRaw) ?? .off }

    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    private var goalKey: String { document.goalKey }

    /// The text column's width: composition mode narrows an unlimited column.
    private var columnWidth: CGFloat {
        isComposing && theme.editorMaxWidth == 0 ? 720 : CGFloat(theme.editorMaxWidth)
    }

    var body: some View {
        NavigationStack {
            presentingSheets(handlingImages(withAlerts(windowContent)))
        }
        // Outside the navigation stack, so the window keeps its title and sidebar button.
        // The inspector's content takes part in the layout even while it's closed, so at a
        // compact width it's empty: a title or toolbar in it would land on the document's bar.
        .inspector(isPresented: Binding(get: { showDashboard && !isComposing && !isCompact }, set: { showDashboard = $0 })) {
            if !isCompact {
                dashboard
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
        .sheet(isPresented: Binding(get: { showDashboardSheet && isCompact }, set: { showDashboardSheet = $0 })) {
            dashboardSheet
        }
    }

    /// Beside the document on iPad; on a phone a sheet (`dashboardSheet`) that closes when it
    /// jumps to a place in the text.
    private var dashboard: some View {
        DashboardView(text: $document.text, goalKey: goalKey, fileURL: fileURL,
                      onJumpToHeading: { heading in leaveDashboard { controller.goToHeading(heading) } },
                      onOpenWikiLink: { target in leaveDashboard { openWikiLink(target) } },
                      onJumpToTag: { tag in leaveDashboard { controller.goToText("#" + tag) } })
    }

    /// The dashboard on a phone: half height to start, so the text shows above it.
    private var dashboardSheet: some View {
        NavigationStack {
            dashboard
                .navigationTitle("Dashboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showDashboardSheet = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    /// On a phone the dashboard covers the text, so it closes before showing the place.
    private func leaveDashboard(_ action: @escaping () -> Void) {
        guard isCompact else { return action() }
        showDashboardSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
    }

    /// The toolbar strip, the editors and the status bar, with the window's title and toolbar.
    private var windowContent: some View {
        VStack(spacing: 0) {
            if !isComposing && !isCompact {
                formattingToolbar(inKeyboard: false)
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
                    formatted
                }
            }
            if !isComposing && !(isCompact && keyboardShown) {
                Divider()
                statusBar
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        .overlay(alignment: .topTrailing) {
            if isComposing {
                Button {
                    isComposing = false
                } label: {
                    Label("Exit Composition", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .padding(12)
            }
        }
        .navigationTitle(Binding(get: { title }, set: { rename(to: $0) }))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            RenameButton()
        }
        .toolbar(isComposing ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(isComposing)
        .persistentSystemOverlays(isComposing ? .hidden : .automatic)
        .onChange(of: document.text) { _, _ in document.textDidChange() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { document.checkForExternalChange() } else { document.autosaveNow() }
        }
        .task(id: document.id) { await watchForExternalChanges() }
        .task(id: document.pendingJump?.id) { await performPendingJump() }
        .focusedSceneValue(\.padDocument, PadDocumentActions(
            controller: controller,
            saveVersion: { document.saveVersion() },
            exportPreview: { showExportPreview = true },
            print: { printDocument() },
            toggleComposition: { isComposing.toggle() },
            toggleDashboard: { if isCompact { showDashboardSheet.toggle() } else { showDashboard.toggle() } },
            toggleTypewriter: { typewriter.toggle() },
            showHelp: { showHelp = true },
            showSettings: { showSettings = true },
            save: { document.autosaveNow() }
        ))
        .onChange(of: effectiveLayout, initial: true) { _, layout in
            controller.setPanes(raw: layout != .preview, formatted: layout != .editor)
        }
        .onAppear {
            if keyboardBar == nil { keyboardBar = PadKeyboardBar(toolbar: formattingToolbar(inKeyboard: true)) }
            document.onExternalConflict = { _, other in conflictText = other }
            controller.openWikiLink = { target in openWikiLink(target) }
            controller.pasteImage = { data, type in insertImage(data: data, name: "pasted", type: type) }
        }
        .toolbar { toolbarContent }
        .onChange(of: fileURL, initial: true) { _, url in
            guard let url else { return }
            // Images beside the document need its folder's saved grant after a relaunch.
            PadFolderAccess.begin(url.deletingLastPathComponent())
            // After a rename (here or in Files), bring its pictures into "<New name>-images".
            if let moved = PadImageStore.adoptPictures(text: document.text, documentURL: url) {
                document.text = moved
                document.textDidChange()
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let target = WikiLink.target(from: url) else { return .systemAction }
            openWikiLink(target)
            return .handled
        })
    }

    private func withAlerts(_ content: some View) -> some View {
        content
        .alert("Changed on Another Device", isPresented: Binding(get: { conflictText != nil }, set: { if !$0 { conflictText = nil } })) {
            Button("Keep This Version") {
                conflictText = nil
                document.autosaveNow()
            }
            Button("Use Other Version") {
                if let other = conflictText { document.useOtherVersion(other) }
                conflictText = nil
            }
        } message: {
            Text("Another device or app saved a different version of \u{201C}\(title)\u{201D} while you were editing it. The version you don\u{2019}t choose stays in More \u{203A} Revert To.")
        }
        .alert("No Sheet Named \u{201C}\(missingLink ?? "")\u{201D}", isPresented: Binding(get: { missingLink != nil }, set: { if !$0 { missingLink = nil } })) {
            Button("Create Sheet") {
                if let target = missingLink { createLinkedSheet(target) }
                missingLink = nil
            }
            Button("Cancel", role: .cancel) { missingLink = nil }
        } message: {
            Text("Create it in \u{201C}\(linkFolder?.lastPathComponent ?? "this folder")\u{201D}?")
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

    private func handlingImages(_ content: some View) -> some View {
        content
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
            Text("\(PadPlatform.systemName) lets Markwright save images beside a document only after you allow its folder once. In the window that opens, check that it shows \(documentFolderName), then tap Open. Folders inside it are covered too.")
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
    }

    private func presentingSheets(_ content: some View) -> some View {
        content
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
        .sheet(item: Binding(get: { controller.tableEdit }, set: { controller.tableEdit = $0 })) { edit in
            PadTableEditorView(edit: edit,
                               onDone: { controller.finishTableEdit(edit, table: $0) },
                               onDelete: { controller.deleteTable(edit) })
        }
    }

    // MARK: - Pieces

    private func formattingToolbar(inKeyboard: Bool) -> PadFormattingToolbar {
        PadFormattingToolbar(controller: controller,
                             onPickPhoto: { showPhotoPicker = true },
                             onPickFile: { showFilePicker = true },
                             inKeyboard: inKeyboard)
    }

    private var editor: some View {
        PadEditorView(
            text: $document.text,
            fontSize: CGFloat(theme.bodyFontSize),
            textColor: theme.useCustomEditorColors ? UIColor(theme.editorTextColor) : .label,
            background: theme.useCustomEditorColors ? UIColor(theme.editorBackground) : nil,
            maxWidth: columnWidth,
            typewriter: typewriter,
            // In Dual, Focus follows the cursor, which is only in one pane.
            focus: controller.isDual && controller.activePane != .raw ? .off : focusMode,
            controller: controller,
            sync: controller.dualSync,
            keyboardAccessory: keyboardAccessory
        )
    }

    private var formatted: some View {
        PadRichEditorView(
            text: $document.text,
            style: formattedStyle,
            baseURL: fileURL,
            typewriter: typewriter,
            focus: focusMode,
            controller: controller,
            sync: controller.dualSync,
            keyboardAccessory: keyboardAccessory
        )
    }

    private var formattedStyle: EditorStyle {
        var style = EditorStyle(theme: theme)
        style.maxWidth = columnWidth
        return style
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
        if showsLibraryButton {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onToggleLibrary) {
                    Label("Library", systemImage: "sidebar.left")
                }
            }
        }
        // The layout switch has a glass capsule of its own; inside the group's shared background
        // it drew a second, offset capsule. So it stands alone, then a gap, then the other buttons.
        ToolbarItem(placement: .primaryAction) {
            Picker("Layout", selection: Binding(get: { effectiveLayout.rawValue }, set: { value in
                controller.layoutWillChange()
                layoutRaw = value
            })) {
                Label("Raw", systemImage: "chevron.left.forwardslash.chevron.right").tag(Layout.editor.rawValue)
                if !isCompact {
                    Label("Dual", systemImage: "rectangle.split.2x1").tag(Layout.split.rawValue)
                }
                Label("Formatted", systemImage: "doc.richtext").tag(Layout.preview.rawValue)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            // On a phone the dashboard is in More, leaving the title room.
            if !isCompact {
                Button {
                    showDashboard.toggle()
                } label: {
                    Label("Dashboard", systemImage: "sidebar.right")
                }
            }

            Menu {
                if isCompact {
                    Button("Dashboard", systemImage: "chart.bar.doc.horizontal") { showDashboardSheet = true }
                    Divider()
                }
                Toggle("Typewriter Scrolling", isOn: $typewriter)
                Picker("Focus", systemImage: "scope", selection: $focusRaw) {
                    ForEach(FocusMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                Button("Composition Mode", systemImage: "arrow.up.left.and.arrow.down.right") { isComposing = true }
                Divider()
                Button("Save a Version", systemImage: "clock.badge.checkmark") { document.saveVersion() }
                Menu("Revert To", systemImage: "clock.arrow.circlepath") {
                    Button("Last Opened") { document.revertToOpened() }
                    if !document.versions.isEmpty {
                        Divider()
                        ForEach(document.versions) { version in
                            Button(version.label) { document.revert(to: version) }
                        }
                    }
                }
                Divider()
                Button("Export Preview…", systemImage: "doc.text.magnifyingglass") { showExportPreview = true }
                Button("Share HTML…", systemImage: "square.and.arrow.up") { share { try PadExporter.htmlFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Share PDF…", systemImage: "square.and.arrow.up") { shareLater { try await PadExporter.pdfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Share Word…", systemImage: "square.and.arrow.up") { shareLater { try await PadExporter.wordFile(markdown: document.text, title: title, documentURL: fileURL) } }
                Button("Share RTF…", systemImage: "square.and.arrow.up") { share { try PadExporter.rtfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL) } }
                Button("Print…", systemImage: "printer") { printDocument() }
                Divider()
                Button("Quick Open…", systemImage: "magnifyingglass") { onQuickOpen() }
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
            // A phone has room for the words; characters and reading time are in the dashboard.
            if !isCompact {
                Text("\(stats.characters.formatted()) chars").foregroundStyle(.tertiary).monospacedDigit()
            }
            if stats.readingMinutes > 0, !isCompact {
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

    /// Shows `[[target]]` in this window: a sheet in the library, or beside this document.
    private func openWikiLink(_ target: String) {
        if let url = WikiLinkResolver.resolve(target, near: fileURL) {
            onOpenFile(url)
        } else if linkFolder == nil {
            showError("Link Not Opened", "Choose a library folder first, then the link can create the sheet.")
        } else {
            missingLink = target
        }
    }

    /// Where a link to a missing sheet creates it: the library, else this document's folder.
    private var linkFolder: URL? {
        LibraryModel.shared.folderURL ?? fileURL?.deletingLastPathComponent()
    }

    private func createLinkedSheet(_ target: String) {
        guard let folder = linkFolder else { return }
        PadFolderAccess.begin(folder)
        let safeName = target.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appending(path: safeName + ".md")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try TextFileIO.write(Data(("# " + target + "\n\n").utf8), to: url)
            }
            LibraryModel.shared.scheduleRefresh()
            onOpenFile(url)
        } catch {
            showError("Sheet Not Created", "\u{201C}\(folder.lastPathComponent)\u{201D} isn't writable: \(error.localizedDescription)")
        }
    }

    // MARK: - File

    private func rename(to name: String) {
        do {
            _ = try PadDocuments.shared.rename(document, to: name)
        } catch {
            showError("Not Renamed", error.localizedDescription)
        }
    }

    /// Changes from another device can arrive while the app stays in front.
    private func watchForExternalChanges() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if UIApplication.shared.applicationState == .active { document.checkForExternalChange() }
        }
    }

    /// Carries out a library search jump once the editor exists.
    private func performPendingJump() async {
        guard let request = document.pendingJump else { return }
        for _ in 0..<20 where controller.textView == nil && controller.rich?.textView == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(150))
        controller.goToText(request.text, options: [.caseInsensitive, .diacriticInsensitive], fromStart: true)
        document.pendingJump = nil
    }

    private func printDocument() {
        Task {
            do { try await PadExporter.print(markdown: document.text, title: title, style: PadExporter.defaultStyle, documentURL: fileURL, from: PadExporter.keyWindowView) }
            catch { showError("Print Failed", error.localizedDescription) }
        }
    }

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
            showError("Image Not Added", "\(PadPlatform.systemName) didn't give Markwright access to \u{201C}\(picked.lastPathComponent)\u{201D}. Try again, or embed the image instead.")
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

/// What the menu bar and keyboard shortcuts can do in the focused window's sheet.
struct PadDocumentActions {
    let controller: PadEditorController
    let saveVersion: () -> Void
    let exportPreview: () -> Void
    let print: () -> Void
    let toggleComposition: () -> Void
    let toggleDashboard: () -> Void
    let toggleTypewriter: () -> Void
    let showHelp: () -> Void
    let showSettings: () -> Void
    let save: () -> Void
}
