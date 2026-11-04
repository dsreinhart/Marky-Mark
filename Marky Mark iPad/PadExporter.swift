//
//  PadExporter.swift
//  Marky Mark iPad
//
//  HTML, PDF and RTF files for the share sheet, printing, and the export preview.
//

import SwiftUI
import UIKit
import WebKit

@MainActor
enum PadExporter {

    static var defaultStyle: ExportStyle {
        get { ExportStyle(rawValue: UserDefaults.standard.string(forKey: "export.style") ?? "") ?? .clean }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "export.style") }
    }

    static func html(markdown: String, title: String, style: ExportStyle) -> String {
        HTMLExporter.document(markdown: markdown, title: title, style: style)
    }

    private static func exportURL(title: String, ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: "/", with: "-")
        return folder.appending(path: (safe.isEmpty ? "Untitled" : safe) + "." + ext)
    }

    static func htmlFile(markdown: String, title: String, style: ExportStyle) throws -> URL {
        let url = try exportURL(title: title, ext: "html")
        try html(markdown: markdown, title: title, style: style).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func rtfFile(markdown: String, title: String, style: ExportStyle) throws -> URL {
        let data = Data(html(markdown: markdown, title: title, style: style).utf8)
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = try exportURL(title: title, ext: "rtf")
        try rtf.write(to: url)
        return url
    }

    static func pdfFile(markdown: String, title: String, style: ExportStyle) throws -> URL {
        let formatter = UIMarkupTextPrintFormatter(markupText: html(markdown: markdown, title: title, style: style))
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter in points
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 54, dy: 54), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, [kCGPDFContextTitle as String: title])
        for index in 0..<max(renderer.numberOfPages, 1) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let url = try exportURL(title: title, ext: "pdf")
        try (data as Data).write(to: url)
        return url
    }

    static func print(markdown: String, title: String, style: ExportStyle, from view: UIView?) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html(markdown: markdown, title: title, style: style))
        if let view {
            controller.present(from: CGRect(x: view.bounds.midX, y: 0, width: 1, height: 1), in: view, animated: true)
        } else {
            controller.present(animated: true)
        }
    }

    static var keyWindowView: UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.rootViewController?.view
    }
}

/// A file to hand to the share sheet.
struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct HTMLWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastHTML = html
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator {
        var lastHTML = ""
    }
}

/// Styled preview of the export with share and print actions.
struct PadExportPreviewView: View {
    let markdown: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var style: ExportStyle = PadExporter.defaultStyle
    @State private var shareFile: ShareFile? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            HTMLWebView(html: PadExporter.html(markdown: markdown, title: title, style: style))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Export Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Picker("Style", selection: $style) {
                            ForEach(ExportStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .onChange(of: style) { _, value in PadExporter.defaultStyle = value }
                        Menu {
                            Button("Share HTML…") { share { try PadExporter.htmlFile(markdown: markdown, title: title, style: style) } }
                            Button("Share PDF…") { share { try PadExporter.pdfFile(markdown: markdown, title: title, style: style) } }
                            Button("Share RTF…") { share { try PadExporter.rtfFile(markdown: markdown, title: title, style: style) } }
                            Divider()
                            Button("Print…") { PadExporter.print(markdown: markdown, title: title, style: style, from: PadExporter.keyWindowView) }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
        }
        .sheet(item: $shareFile) { file in ActivityView(items: [file.url]) }
        .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func share(_ make: () throws -> URL) {
        do { shareFile = ShareFile(url: try make()) } catch { errorMessage = error.localizedDescription }
    }
}
