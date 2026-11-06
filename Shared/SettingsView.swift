//
//  SettingsView.swift
//  Markwright
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var theme = ThemeSettings.shared

    var body: some View {
        TabView {
            editorTab
                .tabItem {
                    Label("Editor", systemImage: "text.alignleft")
                }

            colorsTab
                .tabItem {
                    Label("Colors", systemImage: "paintpalette")
                }

            typographyTab
                .tabItem {
                    Label("Typography", systemImage: "textformat.size")
                }

            #if os(macOS)
            FilesSettingsTab()
                .tabItem {
                    Label("Files", systemImage: "doc")
                }
            #endif
        }
        .frame(width: 480, height: 520)
    }

    private var previewParagraph: AttributedString {
        var result = AttributedString("This is a paragraph with ")
        var code = AttributedString("inline code")
        code.font = .system(size: theme.bodyFontSize, design: .monospaced)
        result.append(code)
        result.append(AttributedString(" and a "))
        var link = AttributedString("link")
        link.foregroundColor = theme.linkColor
        result.append(link)
        return result
    }

    // MARK: - Editor Tab

    #if os(macOS)
    private static let layoutHint = "Typewriter scrolling, focus mode and composition mode live in the View menu."
    #else
    private static let layoutHint = "Typewriter scrolling is in the document's ••• menu."
    #endif

    private var editorTab: some View {
        Form {
            Section("Theme") {
                HStack(spacing: 8) {
                    ForEach(ThemeSettings.presets) { preset in
                        Button {
                            theme.apply(preset)
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(preset.background ?? Color(platform: .mmBackground))
                                    .overlay(
                                        Text("Aa")
                                            .font(.system(size: 15, weight: .semibold, design: preset.font == "serif" ? .serif : (preset.font == "monospaced" ? .monospaced : .default)))
                                            .foregroundStyle(preset.text ?? Color.primary)
                                    )
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(platform: .mmSeparator), lineWidth: 0.5))
                                    .frame(width: 56, height: 40)
                                Text(preset.name).font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                Toggle("Use custom editor colors", isOn: $theme.useCustomEditorColors)
                if theme.useCustomEditorColors {
                    ColorPicker("Editor background", selection: $theme.editorBackground)
                    ColorPicker("Editor text", selection: $theme.editorTextColor)
                }
            }

            Section("Font") {
                Picker("Editor font", selection: $theme.editorFont) {
                    ForEach(ThemeSettings.fontChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                HStack {
                    Text("Line spacing: \(Int(theme.lineSpacing)) pt")
                    Spacer()
                    Slider(value: $theme.lineSpacing, in: 0...14, step: 1)
                        .frame(width: 180)
                }
            }

            Section("Layout") {
                Picker("Editor width", selection: Binding(
                    get: { Int(theme.editorMaxWidth) },
                    set: { theme.editorMaxWidth = Double($0) })) {
                    Text("Narrow (600 pt)").tag(600)
                    Text("Comfortable (760 pt)").tag(760)
                    Text("Wide (960 pt)").tag(960)
                    Text("Full window").tag(0)
                }
                Text(Self.layoutHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Colors Tab

    private var colorsTab: some View {
        Form {
            Section("Headings") {
                ColorPicker("Heading text color", selection: $theme.headingColor)
                Toggle("Show divider under H1 & H2", isOn: $theme.headingDividers)
            }

            Section("Links") {
                ColorPicker("Link color", selection: $theme.linkColor)
            }

            Section("Blockquotes") {
                ColorPicker("Quote bar color", selection: $theme.blockquoteBarColor)
                Toggle("Italic quote text", isOn: $theme.blockquoteItalic)
            }

            Section("Code") {
                ColorPicker("Inline code background", selection: $theme.inlineCodeBackground)
                ColorPicker("Code block background", selection: $theme.codeBlockBackground)
            }

            Section("Other Elements") {
                ColorPicker("Strikethrough text color", selection: $theme.strikethroughColor)
                ColorPicker("Checked task color", selection: $theme.taskCheckedColor)
                ColorPicker("Table header background", selection: $theme.tableHeaderBackground)
            }

            Section {
                Button("Reset All to Defaults") {
                    theme.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Typography Tab

    private var typographyTab: some View {
        Form {
            Section("Body Text") {
                HStack {
                    Text("Font size: \(Int(theme.bodyFontSize)) pt")
                    Spacer()
                    Slider(value: $theme.bodyFontSize, in: 10...24, step: 1)
                        .frame(width: 200)
                }

                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: theme.bodyFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Section("Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Heading Example")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.headingColor)

                    Text(previewParagraph)
                        .font(.system(size: theme.bodyFontSize))

                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.blockquoteBarColor)
                            .frame(width: 4)
                        Text("A blockquote example")
                            .font(.system(size: theme.bodyFontSize))
                            .if(theme.blockquoteItalic) { $0.italic() }
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                    }
                    .frame(height: 28)

                    Text("~~struck through~~")
                        .font(.system(size: theme.bodyFontSize))
                        .strikethrough()
                        .foregroundStyle(theme.strikethroughColor)
                }
                .padding(8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Conditional modifier (available project-wide)

extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

#Preview {
    SettingsView()
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Finder integration: which app opens Markdown files.
private struct FilesSettingsTab: View {
    @State private var defaultApp: String? = nil
    @State private var message: String? = nil

    private static let markdownType = UTType("net.daringfireball.markdown") ?? .plainText

    var body: some View {
        Form {
            Section("Markdown Files") {
                Text("Markwright is listed in Finder's Open With menu for .md files. Make it the default so double-clicking a Markdown file opens it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Current default", value: defaultApp ?? "Unknown")
                Button("Make Markwright the Default") { makeDefault() }
                    .disabled(defaultApp == "Markwright")
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let url = NSWorkspace.shared.urlForApplication(toOpen: Self.markdownType)
        defaultApp = url?.deletingPathExtension().lastPathComponent
    }

    private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: Self.markdownType) { error in
            Task { @MainActor in
                message = error.map { "Could not change the default: \($0.localizedDescription)" } ?? "Markdown files now open in Markwright."
                refresh()
            }
        }
    }
}
#endif
