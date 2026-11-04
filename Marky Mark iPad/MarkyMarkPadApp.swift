//
//  MarkyMarkPadApp.swift
//  Marky Mark iPad
//
//  Document-based iPad app: open Markdown from Files, edit raw with a live preview.
//

import SwiftUI

@main
struct MarkyMarkPadApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownFileDocument()) { file in
            PadDocumentView(document: file.$document, fileURL: file.fileURL)
        }
    }
}
