//
//  MarkwrightPadApp.swift
//  Markwright iPad
//
//  Each window shows the library beside one sheet, as on the Mac. Files opened from the
//  Files app arrive through onOpenURL.
//

import SwiftUI

@main
struct MarkwrightPadApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(for: URL.self) { $fileURL in
            PadRootView(fileURL: $fileURL)
        }
        .commands { PadCommands() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { PadDocuments.shared.saveAll() }
        }
    }
}
