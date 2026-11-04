//
//  ThemeSettings.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI

/// Stores all customizable preview rendering preferences, persisted via UserDefaults.
@Observable
final class ThemeSettings {

    // MARK: - Singleton for environment injection

    static let shared = ThemeSettings()

    // MARK: - Keys

    private enum Keys {
        static let headingColor = "theme.headingColor"
        static let linkColor = "theme.linkColor"
        static let blockquoteBarColor = "theme.blockquoteBarColor"
        static let blockquoteItalic = "theme.blockquoteItalic"
        static let inlineCodeBackground = "theme.inlineCodeBackground"
        static let codeBlockBackground = "theme.codeBlockBackground"
        static let strikethroughColor = "theme.strikethroughColor"
        static let taskCheckedColor = "theme.taskCheckedColor"
        static let tableHeaderBackground = "theme.tableHeaderBackground"
        static let bodyFontSize = "theme.bodyFontSize"
        static let headingDividers = "theme.headingDividers"
        static let editorFont = "theme.editorFont"
        static let lineSpacing = "theme.lineSpacing"
        static let editorMaxWidth = "theme.editorMaxWidth"
        static let useCustomEditorColors = "theme.useCustomEditorColors"
        static let editorBackground = "theme.editorBackground"
        static let editorTextColor = "theme.editorTextColor"
        static let schemaVersion = "theme.schemaVersion"
        static let colorKeys = [headingColor, linkColor, blockquoteBarColor, inlineCodeBackground, codeBlockBackground,
                                strikethroughColor, taskCheckedColor, tableHeaderBackground, editorBackground, editorTextColor]
    }

    /// Bumped when stored values need migrating. Version 2 dropped colors saved by earlier
    /// builds: system colors were archived frozen to the appearance active at save time,
    /// so a color saved in dark mode came back as fixed white in light mode.
    private static let currentSchemaVersion = 2

    // MARK: - Properties

    /// Incremented on every change so views can cheaply detect theme updates.
    private(set) var version = 0

    var headingColor: Color {
        didSet { version += 1; save(headingColor, default: Self.defaultHeadingColor, forKey: Keys.headingColor) }
    }
    var linkColor: Color {
        didSet { version += 1; save(linkColor, default: Self.defaultLinkColor, forKey: Keys.linkColor) }
    }
    var blockquoteBarColor: Color {
        didSet { version += 1; save(blockquoteBarColor, default: Self.defaultBlockquoteBarColor, forKey: Keys.blockquoteBarColor) }
    }
    var blockquoteItalic: Bool {
        didSet { version += 1; UserDefaults.standard.set(blockquoteItalic, forKey: Keys.blockquoteItalic) }
    }
    var inlineCodeBackground: Color {
        didSet { version += 1; save(inlineCodeBackground, default: Self.defaultInlineCodeBackground, forKey: Keys.inlineCodeBackground) }
    }
    var codeBlockBackground: Color {
        didSet { version += 1; save(codeBlockBackground, default: Self.defaultCodeBlockBackground, forKey: Keys.codeBlockBackground) }
    }
    var strikethroughColor: Color {
        didSet { version += 1; save(strikethroughColor, default: Self.defaultStrikethroughColor, forKey: Keys.strikethroughColor) }
    }
    var taskCheckedColor: Color {
        didSet { version += 1; save(taskCheckedColor, default: Self.defaultTaskCheckedColor, forKey: Keys.taskCheckedColor) }
    }
    var tableHeaderBackground: Color {
        didSet { version += 1; save(tableHeaderBackground, default: Self.defaultTableHeaderBackground, forKey: Keys.tableHeaderBackground) }
    }
    var bodyFontSize: Double {
        didSet { version += 1; UserDefaults.standard.set(bodyFontSize, forKey: Keys.bodyFontSize) }
    }
    var headingDividers: Bool {
        didSet { version += 1; UserDefaults.standard.set(headingDividers, forKey: Keys.headingDividers) }
    }
    /// "system", "serif", "rounded", "monospaced", or a font family name.
    var editorFont: String {
        didSet { version += 1; UserDefaults.standard.set(editorFont, forKey: Keys.editorFont) }
    }
    var lineSpacing: Double {
        didSet { version += 1; UserDefaults.standard.set(lineSpacing, forKey: Keys.lineSpacing) }
    }
    /// Maximum line width of the editor in points; 0 means use the full window.
    var editorMaxWidth: Double {
        didSet { version += 1; UserDefaults.standard.set(editorMaxWidth, forKey: Keys.editorMaxWidth) }
    }
    var useCustomEditorColors: Bool {
        didSet { version += 1; UserDefaults.standard.set(useCustomEditorColors, forKey: Keys.useCustomEditorColors) }
    }
    var editorBackground: Color {
        didSet { version += 1; save(editorBackground, default: Self.defaultEditorBackground, forKey: Keys.editorBackground) }
    }
    var editorTextColor: Color {
        didSet { version += 1; save(editorTextColor, default: Self.defaultEditorTextColor, forKey: Keys.editorTextColor) }
    }

    // MARK: - Defaults

    static let defaultHeadingColor = Color(platform: .mmLabel)
    static let defaultLinkColor = Color(platform: .mmLink)
    static let defaultBlockquoteBarColor = Color(platform: .mmAccent)
    static let defaultInlineCodeBackground = Color(platform: .mmSecondaryBackground)
    static let defaultCodeBlockBackground = Color(platform: .mmSecondaryBackground)
    static let defaultStrikethroughColor = Color(platform: .mmSecondaryLabel)
    static let defaultTaskCheckedColor = Color(platform: .systemGreen)
    static let defaultTableHeaderBackground = Color(platform: .mmSecondaryBackground)
    static let defaultEditorBackground = Color(platform: .mmBackground)
    static let defaultEditorTextColor = Color(platform: .mmLabel)
    static let fontChoices: [(id: String, name: String)] = [
        ("system", "System (San Francisco)"), ("serif", "Serif (New York)"), ("rounded", "Rounded"),
        ("monospaced", "Monospaced"), ("Georgia", "Georgia"), ("Palatino", "Palatino"),
        ("Helvetica Neue", "Helvetica Neue"), ("Avenir Next", "Avenir Next"), ("Iowan Old Style", "Iowan Old Style"),
    ]

    // MARK: - Init

    private init() {
        Self.migrateIfNeeded()
        headingColor = Self.load(forKey: Keys.headingColor) ?? Self.defaultHeadingColor
        linkColor = Self.load(forKey: Keys.linkColor) ?? Self.defaultLinkColor
        blockquoteBarColor = Self.load(forKey: Keys.blockquoteBarColor) ?? Self.defaultBlockquoteBarColor
        inlineCodeBackground = Self.load(forKey: Keys.inlineCodeBackground) ?? Self.defaultInlineCodeBackground
        codeBlockBackground = Self.load(forKey: Keys.codeBlockBackground) ?? Self.defaultCodeBlockBackground
        strikethroughColor = Self.load(forKey: Keys.strikethroughColor) ?? Self.defaultStrikethroughColor
        taskCheckedColor = Self.load(forKey: Keys.taskCheckedColor) ?? Self.defaultTaskCheckedColor
        tableHeaderBackground = Self.load(forKey: Keys.tableHeaderBackground) ?? Self.defaultTableHeaderBackground
        blockquoteItalic = UserDefaults.standard.object(forKey: Keys.blockquoteItalic) as? Bool ?? true
        bodyFontSize = UserDefaults.standard.object(forKey: Keys.bodyFontSize) as? Double ?? 14
        headingDividers = UserDefaults.standard.object(forKey: Keys.headingDividers) as? Bool ?? true
        editorFont = UserDefaults.standard.string(forKey: Keys.editorFont) ?? "system"
        lineSpacing = UserDefaults.standard.object(forKey: Keys.lineSpacing) as? Double ?? 3
        editorMaxWidth = UserDefaults.standard.object(forKey: Keys.editorMaxWidth) as? Double ?? 760
        useCustomEditorColors = UserDefaults.standard.object(forKey: Keys.useCustomEditorColors) as? Bool ?? false
        editorBackground = Self.load(forKey: Keys.editorBackground) ?? Self.defaultEditorBackground
        editorTextColor = Self.load(forKey: Keys.editorTextColor) ?? Self.defaultEditorTextColor
    }

    // MARK: - Presets

    struct Preset: Identifiable {
        let id: String
        let name: String
        let background: Color?
        let text: Color?
        let heading: Color?
        let link: Color?
        let quoteBar: Color?
        let font: String?
    }

    static let presets: [Preset] = [
        Preset(id: "default", name: "Default", background: nil, text: nil, heading: nil, link: nil, quoteBar: nil, font: "system"),
        Preset(id: "sepia", name: "Sepia", background: Color(red: 0.96, green: 0.93, blue: 0.85), text: Color(red: 0.36, green: 0.27, blue: 0.21),
               heading: Color(red: 0.30, green: 0.20, blue: 0.14), link: Color(red: 0.55, green: 0.33, blue: 0.14), quoteBar: Color(red: 0.72, green: 0.55, blue: 0.35), font: "serif"),
        Preset(id: "paper", name: "Paper", background: Color(red: 0.99, green: 0.99, blue: 0.98), text: Color(red: 0.15, green: 0.15, blue: 0.17),
               heading: Color(red: 0.10, green: 0.10, blue: 0.12), link: Color(red: 0.20, green: 0.40, blue: 0.75), quoteBar: Color(red: 0.70, green: 0.70, blue: 0.72), font: "Iowan Old Style"),
        Preset(id: "graphite", name: "Graphite", background: Color(red: 0.14, green: 0.15, blue: 0.17), text: Color(red: 0.86, green: 0.87, blue: 0.89),
               heading: Color(red: 0.98, green: 0.98, blue: 1.0), link: Color(red: 0.50, green: 0.72, blue: 1.0), quoteBar: Color(red: 0.45, green: 0.55, blue: 0.70), font: "system"),
        Preset(id: "solarized", name: "Solarized", background: Color(red: 0.99, green: 0.96, blue: 0.89), text: Color(red: 0.40, green: 0.48, blue: 0.51),
               heading: Color(red: 0.03, green: 0.21, blue: 0.26), link: Color(red: 0.15, green: 0.55, blue: 0.82), quoteBar: Color(red: 0.71, green: 0.54, blue: 0.0), font: "serif"),
        Preset(id: "typewriter", name: "Typewriter", background: Color(red: 0.97, green: 0.97, blue: 0.96), text: Color(red: 0.20, green: 0.20, blue: 0.20),
               heading: Color(red: 0.12, green: 0.12, blue: 0.12), link: Color(red: 0.55, green: 0.15, blue: 0.15), quoteBar: Color(red: 0.6, green: 0.6, blue: 0.6), font: "monospaced"),
    ]

    func apply(_ preset: Preset) {
        if let background = preset.background, let text = preset.text {
            useCustomEditorColors = true
            editorBackground = background
            editorTextColor = text
        } else {
            useCustomEditorColors = false
            editorBackground = Self.defaultEditorBackground
            editorTextColor = Self.defaultEditorTextColor
        }
        headingColor = preset.heading ?? Self.defaultHeadingColor
        linkColor = preset.link ?? Self.defaultLinkColor
        blockquoteBarColor = preset.quoteBar ?? Self.defaultBlockquoteBarColor
        if let font = preset.font { editorFont = font }
    }

    // MARK: - Reset

    func resetToDefaults() {
        headingColor = Self.defaultHeadingColor
        linkColor = Self.defaultLinkColor
        blockquoteBarColor = Self.defaultBlockquoteBarColor
        blockquoteItalic = true
        inlineCodeBackground = Self.defaultInlineCodeBackground
        codeBlockBackground = Self.defaultCodeBlockBackground
        strikethroughColor = Self.defaultStrikethroughColor
        taskCheckedColor = Self.defaultTaskCheckedColor
        tableHeaderBackground = Self.defaultTableHeaderBackground
        bodyFontSize = 14
        headingDividers = true
        editorFont = "system"
        lineSpacing = 3
        editorMaxWidth = 760
        useCustomEditorColors = false
        editorBackground = Self.defaultEditorBackground
        editorTextColor = Self.defaultEditorTextColor
    }

    // MARK: - Color persistence helpers

    private static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: Keys.schemaVersion)
        guard stored < currentSchemaVersion else { return }
        if stored < 2 {
            for key in Keys.colorKeys { defaults.removeObject(forKey: key) }
        }
        defaults.set(currentSchemaVersion, forKey: Keys.schemaVersion)
    }

    /// Persists a color only when it differs from the default. Default colors are dynamic
    /// system colors that must never be archived (archiving freezes them to one appearance).
    private func save(_ color: Color, default defaultColor: Color, forKey key: String) {
        guard color != defaultColor else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        #if canImport(AppKit)
        let platformColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        #else
        let platformColor = UIColor(color)
        #endif
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: platformColor,
            requiringSecureCoding: false
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(forKey key: String) -> Color? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let platformColor = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: PlatformColor.self,
                from: data
              ) else { return nil }
        #if canImport(AppKit)
        guard platformColor.usingColorSpace(.sRGB) != nil else { return nil }
        #endif
        return Color(platform: platformColor)
    }
}
