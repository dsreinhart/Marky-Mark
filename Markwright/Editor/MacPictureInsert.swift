//
//  MacPictureInsert.swift
//  Markwright
//
//  A picture chosen with the image button goes in as soon as it is chosen. One already in the
//  document's folder is linked where it is; anything else is copied into "<Document>-images"
//  beside the document (as on the iPad), so the link keeps working after a relaunch and on
//  the iPad. macOS lets the app write there only after the folder is allowed once.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum MacPictureInsert {

    static func insert(fileAt url: URL, controller: RichEditorController, documentURL: URL?, text: String) {
        let alt = url.deletingPathExtension().lastPathComponent
        if let relative = PictureStore.pathInsideDocumentFolder(url, documentURL: documentURL) {
            controller.insertImage(alt: alt, source: relative)
            return
        }
        guard let data = try? Data(contentsOf: url),
              let prepared = PictureStore.prepare(data: data, suggestedName: url.lastPathComponent,
                                                  type: UTType(filenameExtension: url.pathExtension)) else {
            show("Picture Not Added", "\u{201C}\(url.lastPathComponent)\u{201D} couldn't be read as a picture.")
            return
        }
        guard let documentURL else {
            // An untitled document has no folder yet: the picture goes in the text itself.
            insert(PictureStore.embed(prepared), into: controller)
            return
        }
        if let stored = try? PictureStore.storeBeside(prepared, documentURL: documentURL, text: text) {
            insert(stored, into: controller)
        } else {
            askForFolder(prepared, documentURL: documentURL, text: text, controller: controller)
        }
    }

    private static func insert(_ stored: PictureStore.Stored, into controller: RichEditorController) {
        controller.insertImage(alt: stored.alt, source: stored.source)
    }

    /// The document's folder isn't writable yet: offer to allow it, or to embed the picture.
    private static func askForFolder(_ prepared: PictureStore.Prepared, documentURL: URL, text: String,
                                     controller: RichEditorController, wrongFolder: String? = nil) {
        let folder = documentURL.deletingLastPathComponent()
        let name = "\u{201C}\(folder.lastPathComponent)\u{201D}"
        let alert = NSAlert()
        if let wrongFolder {
            alert.messageText = "Allow \(name) Instead?"
            alert.informativeText = "The folder allowed was \u{201C}\(wrongFolder)\u{201D}, but this document is in \(name). Allow \(name), or a folder that contains it, and the picture will be saved there."
        } else {
            alert.messageText = "Allow Access to \(name)?"
            alert.informativeText = "macOS lets Markwright save pictures beside a document only after you allow its folder once. In the window that opens, check that it shows \(name), then click Allow. Folders inside it are covered too."
        }
        alert.addButton(withTitle: "Allow Access\u{2026}")
        alert.addButton(withTitle: "Embed in Text Instead")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertSecondButtonReturn:
            insert(PictureStore.embed(prepared), into: controller)
            return
        default:
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.message = "Allow Markwright to save pictures in \(name)"
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        Diagnostics.log("folder window returned \(picked.path) for document folder \(folder.path)")
        if FolderAccess.grant(picked) == .refused {
            show("Picture Not Added", "macOS didn't give Markwright access to \u{201C}\(picked.lastPathComponent)\u{201D}. Try again, or embed the picture instead.")
            return
        }
        guard FolderAccess.grant(picked, covers: folder) else {
            askForFolder(prepared, documentURL: documentURL, text: text, controller: controller, wrongFolder: picked.lastPathComponent)
            return
        }
        do {
            insert(try PictureStore.storeBeside(prepared, documentURL: documentURL, text: text), into: controller)
        } catch {
            show("Picture Not Added", "Couldn't save it in \(name): \(error.localizedDescription)")
        }
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
