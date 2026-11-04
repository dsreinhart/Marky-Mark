//
//  PlatformSupport.swift
//  Marky Mark
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
}

extension PlatformFont {
    func italicVariant() -> PlatformFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
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
}

extension PlatformFont {
    func italicVariant() -> PlatformFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
#endif
