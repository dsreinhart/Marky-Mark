//
//  HelpBook.swift
//  Markwright
//
//  The user guide: a Markdown file in the bundle, copied into Application Support and opened
//  as an ordinary document so it renders in the editor itself.
//

import AppKit

@MainActor
enum HelpBook {
    static let fileName = "Markwright Help.md"

    private static var bundledURL: URL? {
        Bundle.main.url(forResource: "Markwright Help", withExtension: "md")
    }

    private static var installedURL: URL {
        DocumentStore.supportFolder.appending(path: fileName)
    }

    /// The guide as a document, refreshed from the bundle unless it is already open in a tab.
    static func document() -> Document? {
        let store = DocumentStore.shared
        if let open = store.document(for: installedURL) { return open }
        guard let source = bundledURL, let data = try? Data(contentsOf: source) else { return nil }
        do {
            try data.write(to: installedURL, options: .atomic)
        } catch {
            return nil
        }
        return store.openDocument(at: installedURL)
    }

    /// Help > Markwright Help: shows the guide in a tab, bringing it forward if it is open.
    static func show() {
        guard let document = document() else {
            let alert = NSAlert()
            alert.messageText = "The user guide could not be opened"
            alert.informativeText = "The guide is missing from this copy of Markwright."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        let store = DocumentStore.shared
        if store.hasVisibleWindow, store.openWindowAction != nil {
            store.show(document)
        } else {
            // No window to show it in: reopening the app creates one that picks up the queued file.
            store.enqueue(installedURL)
            NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.bundlePath))
        }
    }
}
