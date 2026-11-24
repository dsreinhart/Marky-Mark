//
//  PadExporter.swift
//  Markwright iPad
//
//  HTML, PDF, RTF and Word files for the share sheet, printing, and the export preview.
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

    static func html(markdown: String, title: String, style: ExportStyle, documentURL: URL? = nil) -> String {
        // Images beside the document can only be read with access to its folder.
        if let folder = documentURL?.deletingLastPathComponent() { PadFolderAccess.begin(folder) }
        return HTMLExporter.document(markdown: markdown, title: title, style: style, documentURL: documentURL)
    }

    private static func exportURL(title: String, ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: "/", with: "-")
        return folder.appending(path: (safe.isEmpty ? "Untitled" : safe) + "." + ext)
    }

    static func htmlFile(markdown: String, title: String, style: ExportStyle, documentURL: URL? = nil) throws -> URL {
        let url = try exportURL(title: title, ext: "html")
        try html(markdown: markdown, title: title, style: style, documentURL: documentURL).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func rtfFile(markdown: String, title: String, style: ExportStyle, documentURL: URL? = nil) throws -> URL {
        let data = Data(html(markdown: markdown, title: title, style: style, documentURL: documentURL).utf8)
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

    /// A Word document. Pictures beside the document or embedded in it go in; pictures on the
    /// web are fetched first (10 seconds each at most) and left as their alt text if that fails.
    static func wordFile(markdown: String, title: String, documentURL: URL? = nil) async throws -> URL {
        let folder = documentURL?.deletingLastPathComponent()
        if let folder { PadFolderAccess.begin(folder) }
        let data = await DocxWriter.document(markdown: markdown, title: title, documentFolder: folder)
        let url = try exportURL(title: title, ext: "docx")
        try data.write(to: url)
        return url
    }

    static func pdfFile(markdown: String, title: String, style: ExportStyle, documentURL: URL? = nil) async throws -> URL {
        let data = try await pdfData(markdown: markdown, title: title, style: style, documentURL: documentURL)
        let url = try exportURL(title: title, ext: "pdf")
        try data.write(to: url)
        return url
    }

    /// Paginated US Letter PDF. Drawn from a web view only after the page and every image in it
    /// have loaded; drawing straight from the HTML left images out, or the whole page blank.
    static func pdfData(markdown: String, title: String, style: ExportStyle, documentURL: URL? = nil) async throws -> Data {
        try await PadPDFRenderer().render(html: html(markdown: markdown, title: title, style: style, documentURL: documentURL),
                                          title: title)
    }

    /// Prints the same pages the PDF export makes.
    static func print(markdown: String, title: String, style: ExportStyle, documentURL: URL? = nil, from view: UIView?) async throws {
        let data = try await pdfData(markdown: markdown, title: title, style: style, documentURL: documentURL)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = data
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

/// Lays HTML out in an off-screen web view, waits for it and its images to load, then draws
/// it page by page into a PDF.
@MainActor
final class PadPDFRenderer: NSObject, WKNavigationDelegate {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter in points
    private static let margin: CGFloat = 54
    private var loaded: CheckedContinuation<Void, Error>?

    func render(html: String, title: String) async throws -> Data {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.page.width - 2 * Self.margin, height: Self.page.height))
        webView.navigationDelegate = self
        // Printing a web view that isn't in a window can come out blank, so park it off screen.
        let host = PadExporter.keyWindowView?.window
        webView.frame.origin = CGPoint(x: -10_000, y: 0)
        host?.addSubview(webView)
        defer { webView.removeFromSuperview() }

        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        // Wait for every image to finish loading and decoding (a broken one doesn't block).
        _ = try? await webView.callAsyncJavaScript("""
            await Promise.all(Array.from(document.images).map(img =>
                img.complete ? img.decode().catch(() => {}) :
                new Promise(done => { img.onload = img.onerror = done })));
            return true;
            """, contentWorld: .page)

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.setValue(Self.page, forKey: "paperRect")
        renderer.setValue(Self.page.insetBy(dx: Self.margin, dy: Self.margin), forKey: "printableRect")
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, Self.page, [kCGPDFContextTitle as String: title])
        for index in 0..<max(renderer.numberOfPages, 1) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
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
    /// The document's file, so images stored beside it are embedded in the preview and exports.
    var documentURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var style: ExportStyle = PadExporter.defaultStyle
    @State private var shareFile: ShareFile? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            HTMLWebView(html: PadExporter.html(markdown: markdown, title: title, style: style, documentURL: documentURL))
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
                            Button("Share HTML…") { share { try PadExporter.htmlFile(markdown: markdown, title: title, style: style, documentURL: documentURL) } }
                            Button("Share PDF…") { shareLater { try await PadExporter.pdfFile(markdown: markdown, title: title, style: style, documentURL: documentURL) } }
                            Button("Share RTF…") { share { try PadExporter.rtfFile(markdown: markdown, title: title, style: style, documentURL: documentURL) } }
                            Divider()
                            Button("Print…") {
                                Task {
                                    do { try await PadExporter.print(markdown: markdown, title: title, style: style, documentURL: documentURL, from: PadExporter.keyWindowView) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
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

    private func shareLater(_ make: @escaping () async throws -> URL) {
        Task {
            do { shareFile = ShareFile(url: try await make()) } catch { errorMessage = error.localizedDescription }
        }
    }
}
