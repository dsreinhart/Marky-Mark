//
//  WikiLinkResolver.swift
//  Markwright
//
//  Opens a `[[Sheet name]]` in a tab, or creates the sheet when the user agrees.
//

import AppKit

extension WikiLinkResolver {
    /// Opens the linked sheet in a tab, offering to create it when it doesn't exist.
    static func open(_ target: String, near documentURL: URL?) {
        let store = DocumentStore.shared
        if let url = resolve(target, near: documentURL) {
            if let document = store.openDocument(at: url) { store.show(document) }
            return
        }
        let folder = LibraryModel.shared.folderURL ?? documentURL?.deletingLastPathComponent()
        let alert = NSAlert()
        alert.messageText = "No sheet named \u{201C}\(target)\u{201D}"
        alert.informativeText = folder == nil
            ? "Save this document or choose a library folder first, then the link can create the sheet."
            : "Create it in \u{201C}\(folder!.lastPathComponent)\u{201D}?"
        alert.alertStyle = .informational
        if folder != nil { alert.addButton(withTitle: "Create Sheet") }
        alert.addButton(withTitle: "Cancel")
        guard folder != nil, alert.runModal() == .alertFirstButtonReturn, let folder else { return }

        let safeName = target.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appending(path: safeName + ".md")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try ("# " + target + "\n\n").write(to: url, atomically: true, encoding: .utf8)
            }
            LibraryModel.shared.scheduleRefresh()
            if let document = store.openDocument(at: url) { store.show(document) }
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not create the sheet"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.runModal()
        }
    }
}
