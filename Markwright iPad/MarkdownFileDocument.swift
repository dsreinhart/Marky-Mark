//
//  MarkdownFileDocument.swift
//  Markwright iPad
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
    /// BOM and line endings of the file as opened, restored on save.
    var format = TextFileFormat()

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        (text, format) = TextFileFormat.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: format.encode(text))
    }
}
