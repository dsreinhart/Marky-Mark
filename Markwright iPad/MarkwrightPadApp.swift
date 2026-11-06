//
//  MarkwrightPadApp.swift
//  Markwright iPad
//
//  Document-based iPad app: open Markdown from Files, edit raw with a live preview.
//

import SwiftUI

@main
struct MarkwrightPadApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownFileDocument()) { file in
            PadDocumentView(document: file.$document, fileURL: file.fileURL)
        }
    }
}
