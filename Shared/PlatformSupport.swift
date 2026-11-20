//
//  PlatformSupport.swift
//  Markwright
//
//  Small shims so the shared code reads the same on macOS and iPadOS.
//

import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont

extension Color {
    init(platform color: PlatformColor) { self.init(nsColor: color) }
}

extension PlatformColor {
    static var mmLabel: PlatformColor { .labelColor }
    static var mmSecondaryLabel: PlatformColor { .secondaryLabelColor }
    static var mmTertiaryLabel: PlatformColor { .tertiaryLabelColor }
    static var mmBackground: PlatformColor { .textBackgroundColor }
    static var mmSecondaryBackground: PlatformColor { .controlBackgroundColor }
    static var mmLink: PlatformColor { .linkColor }
    static var mmAccent: PlatformColor { .controlAccentColor }
    static var mmSeparator: PlatformColor { .separatorColor }
    static var mmWindowBackground: PlatformColor { .windowBackgroundColor }
    static var mmQuaternaryLabel: PlatformColor { .quaternaryLabelColor }
    static var mmControlBackground: PlatformColor { .controlBackgroundColor }
}

extension PlatformFont {
    func italicVariant() -> PlatformFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }

    /// The same font in bold and/or italic.
    func adding(bold: Bool, italic: Bool) -> PlatformFont {
        guard bold || italic else { return self }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont

extension Color {
    init(platform color: PlatformColor) { self.init(uiColor: color) }
}

extension PlatformColor {
    static var mmLabel: PlatformColor { .label }
    static var mmSecondaryLabel: PlatformColor { .secondaryLabel }
    static var mmTertiaryLabel: PlatformColor { .tertiaryLabel }
    static var mmBackground: PlatformColor { .systemBackground }
    static var mmSecondaryBackground: PlatformColor { .secondarySystemBackground }
    static var mmLink: PlatformColor { .link }
    static var mmAccent: PlatformColor { .tintColor }
    static var mmSeparator: PlatformColor { .separator }
    static var mmWindowBackground: PlatformColor { .systemGroupedBackground }
    static var mmQuaternaryLabel: PlatformColor { .quaternaryLabel }
    static var mmControlBackground: PlatformColor { .secondarySystemBackground }
}

extension PlatformFont {
    func italicVariant() -> PlatformFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// The same font in bold and/or italic.
    func adding(bold: Bool, italic: Bool) -> PlatformFont {
        guard bold || italic else { return self }
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
