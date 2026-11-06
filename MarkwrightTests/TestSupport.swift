//
//  TestSupport.swift
//  MarkwrightTests
//
//  This bundle compiles the app's sources directly and runs outside the app, so it never
//  touches the installed app's container, windows, session or preferences. Tests that use
//  files work in temporary folders only.
//

import AppKit
import Foundation
import SwiftUI
import Testing

/// Finds this test bundle's own resources.
final class BundleToken {}

enum TestEnvironment {
    private static let support = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appending(path: "MarkwrightTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Call before using anything that stores data.
    static func prepare() {
        // A hosted run would share the real app's container and preferences. Refuse outright.
        precondition(Bundle.main.bundleIdentifier != "com.gethappyllc.Marky-Mark",
                     "Tests must not run inside the Markwright app")
        _ = NSApplication.shared
        DocumentStore.supportFolderOverride = support
        _ = cleanPreferences
    }

    /// Each run starts from nothing. These are the test tool's own preferences, never the app's.
    private static let cleanPreferences: Void = {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }()
}

/// A temporary folder that disappears with the test.
final class TempFolder {
    let url: URL

    init() {
        TestEnvironment.prepare()
        url = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "MarkwrightTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Folders a test made read-only have to be writable again to be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ text: String, to name: String) -> URL {
        let file = url.appending(path: name)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @discardableResult
    func write(bytes: Data, to name: String) -> URL {
        let file = url.appending(path: name)
        try! bytes.write(to: file)
        return file
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: url.appending(path: name), encoding: .utf8)) ?? "<missing>"
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: name).path)
    }
}

/// Waits for something asynchronous, failing the wait after `seconds`.
@discardableResult
func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A mouse-down on a character of a text view.
func mouseDown(on view: NSTextView, at character: Int, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    let layoutManager = view.layoutManager!
    let container = view.textContainer!
    layoutManager.ensureLayout(for: container)
    let glyph = layoutManager.glyphIndexForCharacter(at: character)
    var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    rect.origin.x += view.textContainerOrigin.x
    rect.origin.y += view.textContainerOrigin.y
    let location = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    return NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: flags, timestamp: 0,
                              windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1,
                              clickCount: 1, pressure: 1)!
}

extension NSTextView {
    var selectedText: String { (string as NSString).substring(with: selectedRange()) }
}

extension String {
    var ns: NSString { self as NSString }
}

/// The formatted editor on its own, in a real text view and window.
final class FormattedEditor {
    var published = ""
    let controller = RichEditorController()
    let coordinator: RichMarkdownEditorView.Coordinator
    let textView: RichMarkdownEditorView.RichTextView
    let window: NSWindow

    init() {
        TestEnvironment.prepare()
        // The binding reaches `published` through a box because `self` isn't available yet.
        let box = TextBox()
        self.box = box
        let view = RichMarkdownEditorView(text: Binding(get: { box.text }, set: { box.text = $0 }),
                                          style: EditorStyle(theme: ThemeSettings.shared), options: EditorOptions(),
                                          baseURL: nil, controller: controller)
        coordinator = RichMarkdownEditorView.Coordinator(view)
        textView = RichMarkdownEditorView.RichTextView(usingTextLayoutManager: false)
        textView.coordinator = coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.smartInsertDeleteEnabled = false
        textView.delegate = coordinator
        textView.layoutManager?.delegate = coordinator
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        coordinator.textView = textView
        controller.coordinator = coordinator
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = textView
    }

    private let box: TextBox
    var text: String { box.text }

    func load(_ markdown: String) { coordinator.load(markdown) }
    func type(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }

    func select(_ needle: String) {
        let range = textView.string.ns.range(of: needle)
        precondition(range.location != NSNotFound, "\(needle) not in text")
        textView.setSelectedRange(range)
    }

    func cursor(after needle: String) {
        let range = textView.string.ns.range(of: needle)
        precondition(range.location != NSNotFound, "\(needle) not in text")
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }
}

final class TextBox {
    var text = ""
}

/// A plain text view for raw formatting commands.
final class RawEditor {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    init() {
        TestEnvironment.prepare()
        textView.isRichText = false
    }

    func load(_ text: String) { textView.string = text }
    func select(_ needle: String) { textView.setSelectedRange(textView.string.ns.range(of: needle)) }
    func cursor(at location: Int) { textView.setSelectedRange(NSRange(location: location, length: 0)) }
    var text: String { textView.string }
    var selected: String { textView.selectedText }
}

/// A long document with everything dual mode has to line up.
let dualDocument: String = {
    var parts = ["""
    # Survey of Lakes

    Opening paragraph with **bold words** and a [link](https://example.com/page) inside it.

    ## Working in Dual

    A section whose note sits here in action.[^1] It carries on after the reference.

    ```
    [^1]: an example inside a code block
    ```

    """]
    for index in 1...30 {
        var section = "## Section \(index)\n\nThe footnote word and plain paragraph text for section number \(index), long enough to wrap onto a second line in a narrow pane so the two panes differ in height.\n\n"
        if index == 12 { section = "## Working with sheets\n\n" + section }
        if index == 25 { section = "## Keyboard shortcuts\n\n" + section }
        section += "- First item of \(index)\n- Second item of \(index)\n\n| Column | Value |\n|---|---|\n| Row \(index) | \(index * 2) |\n\n"
        parts.append(section)
    }
    parts.append("[^1]: Footnote definitions collect at the end.")
    return parts.joined(separator: "\n")
}()

/// Both panes of dual mode, side by side in a real window, wired as the app wires them.
final class DualEditors {
    private let box = TextBox()
    let controller = RichEditorController()
    let window: NSWindow
    let holder: NSView
    var raw: MarkdownEditorView.Coordinator
    var rawView: MarkwrightTextView
    var rawScroll: NSScrollView
    let rich: RichMarkdownEditorView.Coordinator
    let richView: RichMarkdownEditorView.RichTextView
    let richScroll: NSScrollView

    var text: String {
        get { box.text }
        set { box.text = newValue }
    }

    init(_ markdown: String = dualDocument) {
        TestEnvironment.prepare()
        box.text = markdown
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        holder = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        window.contentView = holder

        (raw, rawView, rawScroll) = Self.makeRaw(box: box, controller: controller)

        let binding = Binding(get: { [box] in box.text }, set: { [box] in box.text = $0 })
        let view = RichMarkdownEditorView(text: binding, style: EditorStyle(theme: ThemeSettings.shared),
                                          options: EditorOptions(), baseURL: nil, controller: controller)
        rich = RichMarkdownEditorView.Coordinator(view)
        richView = RichMarkdownEditorView.RichTextView(usingTextLayoutManager: false)
        richView.coordinator = rich
        richView.isRichText = true
        richView.allowsUndo = true
        richView.isEditable = true
        richView.smartInsertDeleteEnabled = false
        richView.delegate = rich
        richView.layoutManager?.delegate = rich
        Self.configure(richView)
        richScroll = NSScrollView(frame: NSRect(x: 500, y: 0, width: 500, height: 700))
        richScroll.hasVerticalScroller = true
        richScroll.documentView = richView
        rich.textView = richView
        rich.baseURL = nil
        rich.load(markdown)
        richView.onTakeFocus = { [weak controller] view in controller?.paneDidTakeFocus(view) }

        holder.addSubview(rawScroll)
        holder.addSubview(richScroll)
        controller.rawCoordinator = raw
        controller.rawTextView = rawView
        controller.coordinator = rich
        controller.refreshActive()
        layOut()
    }

    private static func configure(_ view: NSTextView) {
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = false
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 700)
    }

    private static func makeRaw(box: TextBox, controller: RichEditorController)
        -> (MarkdownEditorView.Coordinator, MarkwrightTextView, NSScrollView) {
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let view = MarkdownEditorView(text: binding, style: EditorStyle(theme: ThemeSettings.shared),
                                      options: EditorOptions(), controller: controller)
        let coordinator = MarkdownEditorView.Coordinator(view)
        let textView = MarkwrightTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.delegate = coordinator
        configure(textView)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        scroll.hasVerticalScroller = true
        // In this order, as in the app: text set outside a scroll view displaces the view.
        scroll.documentView = textView
        textView.string = box.text
        coordinator.textView = textView
        coordinator.scrollView = scroll
        textView.handlesFootnoteClicks = true
        textView.onTakeFocus = { [weak controller] view in controller?.paneDidTakeFocus(view) }
        return (coordinator, textView, scroll)
    }

    func layOut() {
        for view in [rawView as NSTextView, richView as NSTextView] where view.enclosingScrollView != nil {
            view.layoutManager!.ensureLayout(for: view.textContainer!)
            view.sizeToFit()
        }
    }

    func scroll(_ scrollView: NSScrollView, to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Reports an edit made in the raw pane, as typing does.
    func rawEdited() {
        raw.textDidChange(Notification(name: NSText.didChangeNotification))
    }

    /// Replaces the raw pane with a new one, as switching back to a mode that shows it does.
    func addFreshRawPane() {
        (raw, rawView, rawScroll) = Self.makeRaw(box: box, controller: controller)
        holder.addSubview(rawScroll)
        controller.rawCoordinator = raw
        controller.rawTextView = rawView
        controller.refreshActive()
    }
}
