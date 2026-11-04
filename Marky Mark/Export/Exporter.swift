//
//  Exporter.swift
//  Marky Mark
//
//  Export to HTML, PDF, Word and RTF, and printing, all driven from the HTML
//  rendering of the document.
//

import AppKit
import WebKit
import UniformTypeIdentifiers

@MainActor
enum Exporter {

    static var defaultStyle: ExportStyle {
        get { ExportStyle(rawValue: UserDefaults.standard.string(forKey: "export.style") ?? "") ?? .clean }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "export.style") }
    }

    private static func html(for document: Document, style: ExportStyle) -> String {
        let title = document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return HTMLExporter.document(markdown: document.text, title: title, style: style)
    }

    private static func savePanel(for document: Document, type: UTType, extension ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = base + "." + ext
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - HTML / Markdown

    static func exportHTML(_ document: Document, style styleOverride: ExportStyle? = nil) {
        let style = styleOverride ?? defaultStyle
        guard let url = savePanel(for: document, type: .html, extension: "html") else { return }
        do {
            try html(for: document, style: style).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            report(error)
        }
    }

    static func copyHTML(_ document: Document) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(HTMLExporter.body(markdown: document.text), forType: .html)
        pasteboard.setString(document.text, forType: .string)
    }

    // MARK: - Word / RTF

    private static func attributedString(for document: Document, style: ExportStyle) throws -> NSAttributedString {
        let data = Data(html(for: document, style: style).utf8)
        return try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }

    static func exportWord(_ document: Document, style styleOverride: ExportStyle? = nil) {
        let style = styleOverride ?? defaultStyle
        let type = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        guard let url = savePanel(for: document, type: type, extension: "docx") else { return }
        do {
            let text = try attributedString(for: document, style: style)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url)
        } catch {
            report(error)
        }
    }

    static func exportRTF(_ document: Document, style styleOverride: ExportStyle? = nil) {
        let style = styleOverride ?? defaultStyle
        guard let url = savePanel(for: document, type: .rtf, extension: "rtf") else { return }
        do {
            let text = try attributedString(for: document, style: style)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: url)
        } catch {
            report(error)
        }
    }

    // MARK: - PDF / Print (paginated through WebKit's print support)

    static func exportPDF(_ document: Document, style styleOverride: ExportStyle? = nil, window: NSWindow?) {
        let style = styleOverride ?? defaultStyle
        guard let url = savePanel(for: document, type: .pdf, extension: "pdf") else { return }
        Task {
            let renderer = await WebRenderer.render(html: html(for: document, style: style))
            let info = NSPrintInfo(dictionary: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: url])
            configure(info)
            let operation = renderer.webView.printOperation(with: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
            if let window {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
            renderer.keepAlive()
        }
    }

    static func print(_ document: Document, style styleOverride: ExportStyle? = nil, window: NSWindow?) {
        let style = styleOverride ?? defaultStyle
        Task {
            let renderer = await WebRenderer.render(html: html(for: document, style: style))
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            configure(info)
            let operation = renderer.webView.printOperation(with: info)
            operation.showsPrintPanel = true
            operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
            if let window {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
            renderer.keepAlive()
        }
    }

    private static func configure(_ info: NSPrintInfo) {
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
    }
}

/// Loads HTML into an off-screen web view and waits for it to finish.
@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var continuation: CheckedContinuation<Void, Never>?
    private static var live: [WebRenderer] = []

    private override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 816, height: 1056), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    static func render(html: String) async -> WebRenderer {
        let renderer = WebRenderer()
        live.append(renderer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            renderer.continuation = continuation
            renderer.webView.loadHTMLString(html, baseURL: nil)
        }
        // Give images a moment to arrive before printing.
        try? await Task.sleep(for: .milliseconds(300))
        return renderer
    }

    /// Releases the renderer a little later so the print operation can finish using it.
    func keepAlive() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            Self.live.removeAll { $0 === self }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume()
        continuation = nil
    }
}
