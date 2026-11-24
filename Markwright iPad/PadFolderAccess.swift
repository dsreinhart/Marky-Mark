//
//  PadFolderAccess.swift
//  Markwright iPad
//
//  The iPad's folder window for granting a document's folder (FolderAccess, in Shared).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The shared folder grants and log under their iPad names.
typealias PadFolderAccess = FolderAccess
typealias PadDiagnostics = Diagnostics

/// The system folder window, opened at the document's own folder; the user confirms with "Open".
struct FolderPicker: UIViewControllerRepresentable {
    let startingAt: URL?
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.directoryURL = startingAt
        PadDiagnostics.log("folder window opening at \(startingAt?.path ?? "nil")")
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}
