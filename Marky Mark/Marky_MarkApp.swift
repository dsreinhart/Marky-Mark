//
//  Marky_MarkApp.swift
//  Marky Mark
//
//  Created by David Reinhart on 4/22/26.
//

import SwiftUI

@main
struct Marky_MarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            FileCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Intercept kAEOpenDocuments BEFORE SwiftUI registers its own handler.
        // This prevents SwiftUI from creating a new window for "Open With..." events.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )

        // Disable window state restoration.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-register our handler in case SwiftUI replaced it during launch setup.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )

        // Close any extra windows from state restoration.
        DispatchQueue.main.async {
            let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
            for window in visibleWindows.dropFirst() {
                window.close()
            }
            for window in NSApplication.shared.windows {
                window.isRestorable = false
            }
        }
    }

    /// Handles kAEOpenDocuments Apple Events directly, bypassing SwiftUI's window creation.
    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        for i in 1...directObject.numberOfItems {
            guard let descriptor = directObject.atIndex(i) else { continue }

            // Extract the file URL from the descriptor.
            let url: URL?
            if let urlDescriptor = descriptor.coerce(toDescriptorType: typeFileURL),
               let urlString = String(data: urlDescriptor.data, encoding: .utf8) {
                url = URL(string: urlString)
            } else if let stringValue = descriptor.stringValue {
                url = URL(fileURLWithPath: stringValue)
            } else {
                url = nil
            }

            guard let fileURL = url else { continue }

            // Always store as pending so a new window can pick it up if needed.
            DocumentState.shared.pendingFileURL = fileURL

            // If there's a visible window, also load directly into it.
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if hasVisibleWindow, let openAction = DocumentState.shared.openFileAction {
                openAction(fileURL)
                DocumentState.shared.pendingFileURL = nil
            }
        }

        // Bring the app and its window to the foreground.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                // No visible window (it was closed). Reopen the app to trigger
                // SwiftUI to create a new window. The file will be loaded from
                // pendingFileURL in the new window's onAppear.
                NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.bundlePath))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // No visible windows — let the system create one from the WindowGroup.
            return true
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard DocumentState.shared.hasUnsavedChanges else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save changes before quitting?"
        alert.informativeText = "Your unsaved changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            DocumentState.shared.saveAction?()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

/// Custom File menu commands that use FocusedValue to reach the active window.
struct FileCommands: Commands {
    @FocusedValue(\.documentActions) var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                actions?.newDocument()
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("Open...") {
                actions?.openDocument()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                actions?.saveDocument()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As...") {
                actions?.saveDocumentAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}
