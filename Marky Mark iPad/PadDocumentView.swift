//
//  PadDocumentView.swift
//  Marky Mark iPad
//
//  One document: raw editor with formatting toolbar, live preview, dashboard.
//

import SwiftUI
import UIKit

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
    @State private var showExportPreview = false
    @State private var shareFile: ShareFile? = nil
    @State private var errorMessage: String? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
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
                PadFormattingToolbar(controller: controller)
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
                          onJumpToHeading: { controller.jumpToHeading($0) })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar { toolbarContent }
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
        .sheet(isPresented: $showExportPreview) { PadExportPreviewView(markdown: document.text, title: title) }
        .sheet(item: $shareFile) { file in ActivityView(items: [file.url]) }
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
                Button("Share HTML…", systemImage: "square.and.arrow.up") { share { try PadExporter.htmlFile(markdown: document.text, title: title, style: PadExporter.defaultStyle) } }
                Button("Share PDF…", systemImage: "square.and.arrow.up") { share { try PadExporter.pdfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle) } }
                Button("Share RTF…", systemImage: "square.and.arrow.up") { share { try PadExporter.rtfFile(markdown: document.text, title: title, style: PadExporter.defaultStyle) } }
                Button("Print…", systemImage: "printer") {
                    PadExporter.print(markdown: document.text, title: title, style: PadExporter.defaultStyle, from: PadExporter.keyWindowView)
                }
                Divider()
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
}
