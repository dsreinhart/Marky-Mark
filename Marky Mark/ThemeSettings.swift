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
    }

    // MARK: - Properties

    var headingColor: Color {
        didSet { save(headingColor, forKey: Keys.headingColor) }
    }
    var linkColor: Color {
        didSet { save(linkColor, forKey: Keys.linkColor) }
    }
    var blockquoteBarColor: Color {
        didSet { save(blockquoteBarColor, forKey: Keys.blockquoteBarColor) }
    }
    var blockquoteItalic: Bool {
        didSet { UserDefaults.standard.set(blockquoteItalic, forKey: Keys.blockquoteItalic) }
    }
    var inlineCodeBackground: Color {
        didSet { save(inlineCodeBackground, forKey: Keys.inlineCodeBackground) }
    }
    var codeBlockBackground: Color {
        didSet { save(codeBlockBackground, forKey: Keys.codeBlockBackground) }
    }
    var strikethroughColor: Color {
        didSet { save(strikethroughColor, forKey: Keys.strikethroughColor) }
    }
    var taskCheckedColor: Color {
        didSet { save(taskCheckedColor, forKey: Keys.taskCheckedColor) }
    }
    var tableHeaderBackground: Color {
        didSet { save(tableHeaderBackground, forKey: Keys.tableHeaderBackground) }
    }
    var bodyFontSize: Double {
        didSet { UserDefaults.standard.set(bodyFontSize, forKey: Keys.bodyFontSize) }
    }
    var headingDividers: Bool {
        didSet { UserDefaults.standard.set(headingDividers, forKey: Keys.headingDividers) }
    }

    // MARK: - Defaults

    static let defaultHeadingColor = Color.primary
    static let defaultLinkColor = Color.blue
    static let defaultBlockquoteBarColor = Color.accentColor
    static let defaultInlineCodeBackground = Color(.controlBackgroundColor)
    static let defaultCodeBlockBackground = Color(.controlBackgroundColor)
    static let defaultStrikethroughColor = Color.secondary
    static let defaultTaskCheckedColor = Color.green
    static let defaultTableHeaderBackground = Color(.controlBackgroundColor)

    // MARK: - Init

    private init() {
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
    }

    // MARK: - Color persistence helpers

    private func save(_ color: Color, forKey key: String) {
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: NSColor(color),
            requiringSecureCoding: false
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(forKey key: String) -> Color? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSColor.self,
                from: data
              ) else { return nil }
        return Color(nsColor)
    }
}
