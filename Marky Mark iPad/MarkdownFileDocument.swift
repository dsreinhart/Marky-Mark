//
//  MarkdownFileDocument.swift
//  Marky Mark iPad
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

nonisolated struct MarkdownFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownDocument, .plainText]
    static let writableContentTypes: [UTType] = [.markdownDocument, .plainText]

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
