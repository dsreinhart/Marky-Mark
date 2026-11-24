//
//  PadPlatform.swift
//  Markwright iPad
//
//  What differs between the iPad and the iPhone beyond the screen size, which the views handle
//  through the size class: the system's name in messages, and whether there can be more windows.
//

import UIKit

@MainActor
enum PadPlatform {
    /// "iOS" on iPhone, "iPadOS" on iPad, for messages about what the system allows.
    static var systemName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iOS" : "iPadOS"
    }

    /// iPad. On a wide iPhone (landscape on a Max) the system's sidebar button comes and goes,
    /// so it's removed there and the sheet's own Library button is the one way back.
    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Whether "Open in New Window" can work: not on iPhone, which has one window.
    static var supportsWindows: Bool {
        UIApplication.shared.supportsMultipleScenes
    }
}
