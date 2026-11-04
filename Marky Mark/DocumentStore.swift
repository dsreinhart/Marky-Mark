//
//  DocumentStore.swift
//  Marky Mark
//
//  Tracks open documents (one per window tab), the saved session, and window
//  bookkeeping such as tabbing and close confirmation.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class DocumentStore {
    static let shared = DocumentStore()

    private(set) var documents: [Document] = []

    @ObservationIgnored var openWindowAction: ((UUID) -> Void)? = nil
    @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var interceptors: [UUID: WindowCloseInterceptor] = [:]
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var didRestoreSession = false
    @ObservationIgnored var isTerminating = false

    private enum Keys {
        static let session = "openDocuments"
        static let launched = "didLaunchBefore"
        static let legacyBookmark = "lastOpenedFileBookmark"
        static let legacyDraft = "hasUntitledDraft"
    }

    private struct SessionEntry: Codable {
        var bookmark: Data? = nil
        var draftID: UUID? = nil
    }

    private init() {}

    /// Lets tests point the store at a scratch folder.
    nonisolated(unsafe) static var supportFolderOverride: URL? = nil

    static var supportFolder: URL {
        let base = supportFolderOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = supportFolderOverride ?? base.appending(path: "Marky Mark", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Lookup

    func document(id: UUID) -> Document? {
        documents.first { $0.id == id }
    }

    func document(for url: URL) -> Document? {
        let path = url.standardizedFileURL.path
        return documents.first { $0.fileURL?.standardizedFileURL.path == path }
    }

    // MARK: - Creating & opening

    func newDocument(text: String = "") -> Document {
        let document = Document(text: text)
        add(document)
        return document
    }

    /// Opens a file, or returns the already-open document for it.
    func openDocument(at url: URL) -> Document? {
        if let existing = document(for: url) { return existing }
        do {
            let document = try Document.open(url: url)
            add(document)
            return document
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open file"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
    }

    private func add(_ document: Document) {
        documents.append(document)
        document.onFileChange = { [weak self] in self?.saveSession() }
        saveSession()
    }

    /// Brings the document's tab forward, opening a window for it if needed.
    func show(_ document: Document) {
        if let window = windows[document.id] {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(document.id)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Launch

    /// Documents for the first window of the app: the previous session, plus any files the
    /// app was launched with. Later value-less windows get a fresh untitled document.
    func initialDocuments() -> [Document] {
        var docs: [Document] = []
        if !didRestoreSession {
            didRestoreSession = true
            docs = restoreSession()
        }
        let pending = pendingURLs
        pendingURLs = []
        for url in pending {
            if let document = openDocument(at: url), !docs.contains(where: { $0 === document }) {
                docs.append(document)
            }
        }
        if docs.isEmpty {
            let firstLaunch = !UserDefaults.standard.bool(forKey: Keys.launched)
            docs = [newDocument(text: firstLaunch ? ContentView.sampleMarkdown : "")]
        }
        UserDefaults.standard.set(true, forKey: Keys.launched)
        return docs
    }

    /// Queues a file to open once the first window exists.
    func enqueue(_ url: URL) {
        pendingURLs.append(url)
    }

    // MARK: - Session persistence

    func saveSession() {
        guard !isTerminating else { return }
        let entries: [SessionEntry] = documents.compactMap { document in
            if let bookmark = document.bookmarkData { return SessionEntry(bookmark: bookmark) }
            if !document.text.isEmpty { return SessionEntry(draftID: document.id) }
            return nil
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Keys.session)
        }
    }

    private func restoreSession() -> [Document] {
        let defaults = UserDefaults.standard
        var entries: [SessionEntry] = []
        if let data = defaults.data(forKey: Keys.session),
           let decoded = try? JSONDecoder().decode([SessionEntry].self, from: data) {
            entries = decoded
        }
        // Migrate the single-document keys used by earlier builds.
        if let legacy = defaults.data(forKey: Keys.legacyBookmark) {
            entries.insert(SessionEntry(bookmark: legacy), at: 0)
            defaults.removeObject(forKey: Keys.legacyBookmark)
        }
        if defaults.bool(forKey: Keys.legacyDraft) {
            let old = Self.supportFolder.appending(path: "Untitled Draft.md")
            if let text = try? String(contentsOf: old, encoding: .utf8), !text.isEmpty {
                let id = UUID()
                try? text.write(to: Document.draftURL(for: id), atomically: true, encoding: .utf8)
                entries.append(SessionEntry(draftID: id))
            }
            try? FileManager.default.removeItem(at: old)
            defaults.removeObject(forKey: Keys.legacyDraft)
        }

        var docs: [Document] = []
        for entry in entries {
            if let bookmark = entry.bookmark {
                guard let document = Document.restore(bookmark: bookmark),
                      let url = document.fileURL, self.document(for: url) == nil else { continue }
                add(document)
                docs.append(document)
            } else if let id = entry.draftID, let text = Document.loadDraft(id: id), !text.isEmpty {
                let document = Document(id: id, text: text)
                add(document)
                docs.append(document)
            }
        }
        saveSession()
        return docs
    }

    // MARK: - Windows

    func register(window: NSWindow, for document: Document) {
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "com.gethappyllc.Marky-Mark.document"
        window.isRestorable = false
        let isNew = windows[document.id] !== window
        windows[document.id] = window
        if isNew {
            // Join the existing documents' tab group instead of opening a separate window.
            let others = windows.values.filter { $0 !== window && $0.isVisible }
            if let host = others.first(where: { $0.isKeyWindow }) ?? others.first,
               window.tabGroup == nil || window.tabGroup !== host.tabGroup {
                host.addTabbedWindow(window, ordered: .above)
            }
        }
        if interceptors[document.id] == nil {
            let interceptor = WindowCloseInterceptor(documentID: document.id, original: window.delegate)
            window.delegate = interceptor
            interceptors[document.id] = interceptor
        }
    }

    var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    /// Called before a tab closes. Titled documents auto-save; untitled work asks.
    func windowShouldClose(documentID: UUID) -> Bool {
        guard let document = document(id: documentID) else { return true }
        if !document.isUntitled {
            if !document.autosaveNow() {
                return confirmDiscardUnsavable(document)
            }
            return true
        }
        guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            document.removeDraft()
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save this document?"
        alert.informativeText = "Your changes to \"Untitled\" will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveAs(document)
        case .alertSecondButtonReturn:
            document.removeDraft()
            return true
        default:
            return false
        }
    }

    private func confirmDiscardUnsavable(_ document: Document) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\"\(document.title)\" could not be saved"
        alert.informativeText = "The file may have been moved or is no longer writable. Save it somewhere else, or close and lose the changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveAs(document)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(documentID: UUID) {
        windows[documentID] = nil
        interceptors[documentID] = nil
        guard !isTerminating else { return }
        if let document = document(id: documentID), !document.isUntitled {
            document.autosaveNow()
        }
        documents.removeAll { $0.id == documentID }
        saveSession()
    }

    /// Saves everything before quitting. Returns the titled documents that could not be written.
    func flushForTermination() -> [Document] {
        saveSession()
        isTerminating = true
        return documents.filter { !$0.autosaveNow() }
    }

    // MARK: - Save & open panels

    func save(_ document: Document) {
        if !document.save() {
            saveAs(document)
        }
    }

    @discardableResult
    func saveAs(_ document: Document) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = document.isUntitled ? "Untitled.md" : document.title
        panel.message = "Save your Markdown file"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try document.write(to: url)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save file"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose Markdown files to open"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let document = openDocument(at: url) { show(document) }
        }
    }

    /// Opens a file handed to the app by Finder (Open With, drag to Dock icon).
    func openFromFinder(_ url: URL) {
        if let document = openDocument(at: url) { show(document) }
    }
}

// MARK: - Window close interception

/// Sits in front of SwiftUI's window delegate to confirm closing and to track closed tabs,
/// forwarding everything else to the original delegate.
nonisolated final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    private let documentID: UUID
    private weak var original: NSWindowDelegate?

    init(documentID: UUID, original: NSWindowDelegate?) {
        self.documentID = documentID
        self.original = original
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard DocumentStore.shared.windowShouldClose(documentID: documentID) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        DocumentStore.shared.windowWillClose(documentID: documentID)
        original?.windowWillClose?(notification)
    }
}

// MARK: - Window access from SwiftUI

/// Reports the NSWindow hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
