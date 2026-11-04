//
//  ExportPreviewView.swift
//  Marky Mark
//
//  Live preview of the exported document with a style picker and export actions.
//

import SwiftUI
import WebKit

struct ExportPreviewView: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss
    @State private var style: ExportStyle = Exporter.defaultStyle

    private var html: String {
        HTMLExporter.document(markdown: document.text,
                              title: document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
                              style: style)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Export Preview").font(.headline)
                Picker("Style", selection: $style) {
                    ForEach(ExportStyle.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 200)
                .onChange(of: style) { _, value in Exporter.defaultStyle = value }
                Spacer()
                Menu("Export") {
                    Button("HTML…") { Exporter.exportHTML(document, style: style) }
                    Button("PDF…") { Exporter.exportPDF(document, style: style, window: NSApp.keyWindow) }
                    Button("Word (.docx)…") { Exporter.exportWord(document, style: style) }
                    Button("Rich Text (.rtf)…") { Exporter.exportRTF(document, style: style) }
                    Divider()
                    Button("Copy as HTML") { Exporter.copyHTML(document) }
                }
                .fixedSize()
                Button("Print…") { Exporter.print(document, style: style, window: NSApp.keyWindow) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.bar)
            Divider()
            HTMLPreview(html: html)
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 720)
    }
}

struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastHTML = html
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML = ""
    }
}
