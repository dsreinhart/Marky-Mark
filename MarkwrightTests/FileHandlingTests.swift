//
//  FileHandlingTests.swift
//  MarkwrightTests
//
//  The code that reads and writes people's files. These share app-wide state (the document
//  store, library and goals), so the whole group runs one test at a time. All files live in
//  temporary folders. Where a test is marked as a known issue, the behaviour it describes is
//  what the app should do and doesn't yet; the mark makes the test fail once it's fixed, as a
//  reminder to remove the mark.
//

import AppKit
import Foundation
import Testing

@Suite("File handling", .serialized)
struct FileHandling {}

// MARK: - File format

extension FileHandling {
    @Suite("File format")
    struct FileFormat {
        @Test func bomAndWindowsLineEndingsSurvive() {
            let bytes = TextFileFormat.bom + Data("line one\r\nline two\r\n".utf8)
            let decoded = TextFileFormat.decode(bytes)
            #expect(decoded.text == "line one\nline two\n")
            #expect(decoded.format.hasBOM)
            #expect(decoded.format.lineEnding == .crlf)
            #expect(decoded.format.encode(decoded.text) == bytes)
        }

        @Test func plainFileIsUntouched() {
            let decoded = TextFileFormat.decode(Data("a\nb".utf8))
            #expect(decoded.text == "a\nb")
            #expect(!decoded.format.hasBOM)
            #expect(decoded.format.lineEnding == .lf)
            #expect(decoded.format.encode("a\nb") == Data("a\nb".utf8))
        }

        @Test func classicMacLineEndingsSurvive() {
            let decoded = TextFileFormat.decode(Data("a\rb".utf8))
            #expect(decoded.text == "a\nb")
            #expect(decoded.format.lineEnding == .cr)
            #expect(decoded.format.encode(decoded.text) == Data("a\rb".utf8))
        }

        @Test func emptyFile() {
            let decoded = TextFileFormat.decode(Data())
            #expect(decoded.text == "")
            #expect(decoded.format.encode("") == Data())
        }

        @Test func nonUTF8FallsBackWithoutLosingText() {
            let decoded = TextFileFormat.decode(Data([0x63, 0x61, 0x66, 0xE9]))   // "café" in Windows-1252
            #expect(decoded.text == "café")
        }

        @Test func emojiAndAccentsSurvive() {
            let text = "Café 🎉 naïve"
            let decoded = TextFileFormat.decode(Data(text.utf8))
            #expect(decoded.text == text)
            #expect(decoded.format.encode(decoded.text) == Data(text.utf8))
        }

        /// UTF-16 files, common from older Windows tools, are read byte by byte as Windows-1252:
        /// the text shows as garbage, and the next save writes that garbage over the file.
        @Test func utf16TextIsReadCorrectly() {
            let bytes = "hello".data(using: .utf16)!   // includes a byte-order mark
            withKnownIssue("UTF-16 is not recognised") {
                #expect(TextFileFormat.decode(bytes).text == "hello")
            }
        }
    }
}

// MARK: - Saving

extension FileHandling {
    @Suite("Saving")
    struct Saving {
        @Test func opensAndSavesAnEdit() throws {
            let folder = TempFolder()
            let file = folder.write("original", to: "note.md")
            let document = try Document.open(url: file)
            #expect(document.text == "original")
            #expect(document.title == "note.md")
            #expect(!document.hasUnsavedChanges)
            #expect(!document.isUntitled)

            document.text = "changed"
            document.textDidChange()
            #expect(document.hasUnsavedChanges)
            #expect(document.windowTitle == "note.md — Edited")
            #expect(document.save())
            #expect(folder.read("note.md") == "changed")
            #expect(!document.hasUnsavedChanges)
            #expect(document.windowTitle == "note.md")
        }

        @Test func openingAMissingFileThrows() {
            let folder = TempFolder()
            #expect(throws: (any Error).self) {
                try Document.open(url: folder.url.appending(path: "nothing-here.md"))
            }
        }

        @Test func typingBackTheOriginalIsNotAChange() throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("same", to: "a.md"))
            document.text = "different"
            document.textDidChange()
            document.text = "same"
            document.textDidChange()
            #expect(!document.hasUnsavedChanges)
        }

        @Test func bomAndLineEndingsAreWrittenBack() throws {
            let folder = TempFolder()
            let file = folder.write(bytes: TextFileFormat.bom + Data("one\r\ntwo\r\n".utf8), to: "windows.md")
            let document = try Document.open(url: file)
            #expect(document.text == "one\ntwo\n")
            document.text = "one\ntwo\nthree\n"
            document.textDidChange()
            #expect(document.save())
            #expect(try Data(contentsOf: file) == TextFileFormat.bom + Data("one\r\ntwo\r\nthree\r\n".utf8))
        }

        @Test func unwritableFileReportsFailureAndKeepsTheText() throws {
            let folder = TempFolder()
            let file = folder.write("original", to: "locked.md")
            let document = try Document.open(url: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }

            document.text = "my unsaved work"
            document.textDidChange()
            #expect(!document.save())
            #expect(document.text == "my unsaved work", "nothing typed may be lost")
            #expect(document.hasUnsavedChanges)
            #expect(folder.read("locked.md") == "original")
        }

        @Test func deletedFileReportsFailureAndKeepsTheText() throws {
            let folder = TempFolder()
            let file = folder.write("original", to: "gone.md")
            let document = try Document.open(url: file)
            try FileManager.default.removeItem(at: file)
            document.text = "my unsaved work"
            document.textDidChange()
            let saved = document.save()
            #expect(document.text == "my unsaved work")
            // Either it reports failure, or it put the work back on disk. Silent loss is the failure.
            if saved {
                #expect(folder.read("gone.md") == "my unsaved work")
            } else {
                #expect(document.hasUnsavedChanges)
            }
        }

        @Test func untitledCannotSaveDirectly() {
            TestEnvironment.prepare()
            let document = Document(text: "words")
            #expect(document.isUntitled)
            #expect(document.title == "Untitled")
            #expect(!document.save())
        }

        @Test func saveAsAdoptsTheNewFile() throws {
            let folder = TempFolder()
            let document = Document(text: "brand new")
            let target = folder.url.appending(path: "saved.md")
            try document.write(to: target)
            #expect(folder.read("saved.md") == "brand new")
            #expect(document.fileURL == target)
            #expect(!document.isUntitled)
            #expect(!document.hasUnsavedChanges)
            #expect(document.versions.count == 1)

            document.text = "edited after"
            document.textDidChange()
            #expect(document.save(), "later saves go to the new file")
            #expect(folder.read("saved.md") == "edited after")
        }

        @Test func saveAsLeavesTheOldFileAlone() throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("first", to: "old.md"))
            document.text = "second"
            document.textDidChange()
            try document.write(to: folder.url.appending(path: "new.md"))
            #expect(folder.read("old.md") == "first")
            #expect(folder.read("new.md") == "second")
        }

        @Test func autosaveWritesAfterAPause() async throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("before", to: "auto.md"))
            document.text = "after"
            document.textDidChange()
            #expect(folder.read("auto.md") == "before", "not on every keystroke")
            #expect(await waitUntil(seconds: 4) { folder.read("auto.md") == "after" })
            #expect(!document.hasUnsavedChanges)
        }

        @Test func autosaveNowWritesImmediately() throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("before", to: "now.md"))
            document.text = "after"
            document.textDidChange()
            #expect(document.autosaveNow())
            #expect(folder.read("now.md") == "after")
        }

        @Test func autosaveWithNoChangesDoesNotTouchTheFile() throws {
            let folder = TempFolder()
            let file = folder.write("steady", to: "same.md")
            let document = try Document.open(url: file)
            let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            #expect(document.autosaveNow())
            let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            #expect(before == after)
        }

        /// A file changed elsewhere, such as on the iPad through iCloud Drive, is overwritten by
        /// the next save here, and the other copy can't be recovered from version history.
        @Test func saveDoesNotDestroyChangesMadeElsewhere() throws {
            let folder = TempFolder()
            let file = folder.write("original", to: "shared.md")
            let document = try Document.open(url: file)
            try "written on the iPad".write(to: file, atomically: true, encoding: .utf8)

            document.text = "typed on the Mac"
            document.textDidChange()
            _ = document.save()

            let onDisk = folder.read("shared.md")
            let inHistory = document.versions.contains {
                (try? String(contentsOf: $0.url, encoding: .utf8)) == "written on the iPad"
            }
            withKnownIssue("The other device's text is lost") {
                #expect(onDisk == "written on the iPad" || inHistory)
            }
        }

        @Test func reopeningRestoresFromBookmark() throws {
            let folder = TempFolder()
            let file = folder.write("kept", to: "bookmarked.md")
            let bookmark = try #require(try Document.open(url: file).bookmarkData)
            let restored = try #require(Document.restore(bookmark: bookmark))
            #expect(restored.text == "kept")
            #expect(restored.fileURL?.lastPathComponent == "bookmarked.md")
        }

        @Test func bookmarkFollowsARename() throws {
            let folder = TempFolder()
            let file = folder.write("kept", to: "before.md")
            let bookmark = try #require(try Document.open(url: file).bookmarkData)
            try FileManager.default.moveItem(at: file, to: folder.url.appending(path: "after.md"))
            let restored = try #require(Document.restore(bookmark: bookmark))
            #expect(restored.text == "kept")
            #expect(restored.fileURL?.lastPathComponent == "after.md")
        }

        @Test func restoreSkipsDeletedAndTrashedFiles() throws {
            let folder = TempFolder()
            let file = folder.write("x", to: "doomed.md")
            let bookmark = try #require(try Document.open(url: file).bookmarkData)
            try FileManager.default.removeItem(at: file)
            #expect(Document.restore(bookmark: bookmark) == nil)

            let trashed = folder.write("x", to: ".Trash/old.md")
            let inTrash = try #require(try Document.open(url: trashed).bookmarkData)
            #expect(Document.restore(bookmark: inTrash) == nil)
        }

        @Test func fileMoveKeepsSavingToTheNewPlace() throws {
            let folder = TempFolder()
            let file = folder.write("text", to: "old.md")
            let document = try Document.open(url: file)
            let target = folder.url.appending(path: "moved.md")
            try FileManager.default.moveItem(at: file, to: target)
            var told = false
            document.onFileChange = { told = true }
            document.fileMoved(to: target)
            #expect(told)
            #expect(document.title == "moved.md")
            document.text = "text 2"
            document.textDidChange()
            #expect(document.save())
            #expect(folder.read("moved.md") == "text 2")
            #expect(!folder.exists("old.md"))
        }
    }
}

// MARK: - Drafts

extension FileHandling {
    @Suite("Untitled drafts")
    struct Drafts {
        @Test func untitledWorkIsKeptAsADraft() {
            TestEnvironment.prepare()
            let document = Document(text: "")
            document.text = "not saved anywhere yet"
            document.textDidChange()
            #expect(document.autosaveNow())
            #expect(Document.loadDraft(id: document.id) == "not saved anywhere yet")
            document.removeDraft()
            #expect(Document.loadDraft(id: document.id) == nil)
        }

        @Test func savingAsRemovesTheDraft() throws {
            let folder = TempFolder()
            let document = Document(text: "")
            document.text = "draft text"
            document.textDidChange()
            document.autosaveNow()
            #expect(Document.loadDraft(id: document.id) != nil)
            try document.write(to: folder.url.appending(path: "now-real.md"))
            #expect(Document.loadDraft(id: document.id) == nil)
        }

        @Test func accentsAndEmojiSurviveADraft() {
            TestEnvironment.prepare()
            let document = Document(text: "")
            document.text = "Café 🎉"
            document.textDidChange()
            document.autosaveNow()
            #expect(Document.loadDraft(id: document.id) == "Café 🎉")
            document.removeDraft()
        }
    }
}

// MARK: - Versions

extension FileHandling {
    @Suite("Versions")
    struct Versions {
        /// Versions are named by the millisecond, so tests space them out.
        private func spacing() async { try? await Task.sleep(for: .milliseconds(3)) }

        private func content(of version: DocumentVersion) -> String? {
            try? String(contentsOf: version.url, encoding: .utf8)
        }

        @Test func openingKeepsTheOriginal() throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("as opened", to: "v.md"))
            #expect(document.versions.count == 1)
            #expect(content(of: document.versions[0]) == "as opened")
        }

        @Test func versionsAreNotBesideTheDocument() throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("x", to: "v.md"))
            document.saveVersion()
            let items = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            #expect(items == ["v.md"])
        }

        @Test func saveAVersionKeepsTheCurrentText() async throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("one", to: "v.md"))
            await spacing()
            document.text = "two"
            document.saveVersion()
            #expect(document.versions.count == 2)
            #expect(content(of: document.versions[0]) == "two", "newest first")
        }

        @Test func unchangedTextIsNotStoredTwice() throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("one", to: "v.md"))
            document.saveVersion()
            document.saveVersion()
            #expect(document.versions.count == 1)
        }

        @Test func revertRestoresAndCanBeUndone() async throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("first", to: "v.md"))
            let first = try #require(document.versions.first)
            await spacing()
            document.text = "second"
            document.textDidChange()
            document.revert(to: first)
            #expect(document.text == "first")
            #expect(document.versions.contains { content(of: $0) == "second" }, "what you left is kept")
        }

        @Test func revertToOpenedRestoresTheOpenedText() async throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("opened", to: "v.md"))
            await spacing()
            document.text = "edited"
            document.textDidChange()
            document.save()
            document.revertToOpened()
            #expect(document.text == "opened")
            #expect(document.hasUnsavedChanges)
            #expect(document.versions.contains { content(of: $0) == "edited" })
        }

        @Test func oldestAreDroppedPastTheLimit() async throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("start", to: "v.md"))
            for index in 0..<(Document.maxVersions + 3) {
                await spacing()
                document.text = "text \(index)"
                document.saveVersion()
            }
            #expect(document.versions.count == Document.maxVersions)
            #expect(content(of: document.versions[0]) == "text \(Document.maxVersions + 2)", "the newest stay")
            #expect(!document.versions.contains { content(of: $0) == "start" }, "the oldest goes")
        }

        @Test func filesWithTheSameNameKeepSeparateHistories() async throws {
            let folder = TempFolder()
            let one = try Document.open(url: folder.write("in one", to: "a/same.md"))
            let two = try Document.open(url: folder.write("in two", to: "b/same.md"))
            #expect(one.versions.count == 1)
            #expect(two.versions.count == 1)
            #expect(content(of: one.versions[0]) == "in one")
            #expect(content(of: two.versions[0]) == "in two")
        }

        /// Renaming a file moves its goal but leaves its version history behind.
        @Test func renamingKeepsTheVersionHistory() throws {
            let folder = TempFolder()
            let file = folder.write("text", to: "before.md")
            let document = try Document.open(url: file)
            #expect(document.versions.count == 1)
            let target = folder.url.appending(path: "after.md")
            try FileManager.default.moveItem(at: file, to: target)
            document.fileMoved(to: target)
            withKnownIssue("History stays under the old name") {
                #expect(document.versions.count == 1)
            }
        }
    }
}

// MARK: - Document store and session

extension FileHandling {
    @Suite("Session")
    struct Session {
        private let store = DocumentStore.shared
        private static let sessionKey = "openDocuments"

        private func clear() {
            TestEnvironment.prepare()
            store.isTerminating = false
            for document in store.documents {
                document.removeDraft()
                store.windowWillClose(documentID: document.id)
            }
        }

        @Test func newDocumentsAreTracked() {
            clear()
            let document = store.newDocument(text: "hello")
            #expect(store.document(id: document.id) === document)
            store.windowWillClose(documentID: document.id)
            #expect(store.document(id: document.id) == nil)
        }

        @Test func openingTheSameFileTwiceGivesOneDocument() throws {
            clear()
            let folder = TempFolder()
            let file = folder.write("once", to: "one.md")
            let first = try #require(store.openDocument(at: file))
            let second = try #require(store.openDocument(at: file))
            #expect(first === second)
            #expect(store.documents.count == 1)
            clear()
        }

        /// One test covers restoring, because the store restores only once per launch.
        @Test func sessionComesBackWithFilesAndDrafts() throws {
            clear()
            let defaults = UserDefaults.standard
            let folder = TempFolder()
            let kept = folder.write("kept file", to: "kept.md")
            let doomed = folder.write("doomed file", to: "doomed.md")
            let file = try #require(store.openDocument(at: kept))
            let goneFile = try #require(store.openDocument(at: doomed))
            let draft = store.newDocument(text: "")
            draft.text = "unsaved draft"
            draft.textDidChange()
            draft.autosaveNow()
            let empty = store.newDocument(text: "")
            store.saveSession()
            let saved = try #require(defaults.data(forKey: Self.sessionKey))
            let draftID = draft.id
            _ = (file, goneFile, empty)

            // Quit: everything closes, then the session as it stood is what comes back.
            for document in store.documents { store.windowWillClose(documentID: document.id) }
            try FileManager.default.removeItem(at: doomed)
            defaults.set(saved, forKey: Self.sessionKey)

            let restored = store.initialDocuments()
            #expect(restored.map(\.text).contains("kept file"))
            #expect(restored.first { $0.id == draftID }?.text == "unsaved draft")
            #expect(!restored.map(\.text).contains("doomed file"), "a deleted file is dropped, not an error")
            #expect(restored.count == 2, "the empty untitled document isn't brought back")

            // Later windows don't restore again.
            let later = store.initialDocuments()
            #expect(later.count == 1)
            #expect(later[0].text.isEmpty)
            clear()
        }

        @Test func quittingSavesEverythingAndReportsFailures() throws {
            clear()
            let folder = TempFolder()
            let good = try #require(store.openDocument(at: folder.write("a", to: "good.md")))
            good.text = "a changed"
            good.textDidChange()
            let lockedFolder = TempFolder()
            let bad = try #require(store.openDocument(at: lockedFolder.write("b", to: "bad.md")))
            bad.text = "b changed"
            bad.textDidChange()
            let draft = store.newDocument(text: "")
            draft.text = "draft text"
            draft.textDidChange()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedFolder.url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedFolder.url.path) }

            let failed = store.flushForTermination()
            store.isTerminating = false
            #expect(failed.map(\.id) == [bad.id])
            #expect(folder.read("good.md") == "a changed")
            #expect(Document.loadDraft(id: draft.id) == "draft text")
            clear()
        }

        @Test func closingATabSavesIt() throws {
            clear()
            let folder = TempFolder()
            let document = try #require(store.openDocument(at: folder.write("a", to: "close.md")))
            document.text = "edited"
            document.textDidChange()
            store.windowWillClose(documentID: document.id)
            #expect(folder.read("close.md") == "edited")
            #expect(store.document(id: document.id) == nil)
        }

        @Test func closingAnEmptyUntitledAsksNothing() {
            clear()
            let document = store.newDocument(text: "   \n ")
            #expect(store.windowShouldClose(documentID: document.id))
            store.windowWillClose(documentID: document.id)
        }

        @Test func recentsListNewestFirstWithoutDuplicates() throws {
            clear()
            store.clearRecents()
            let folder = TempFolder()
            let a = folder.write("a", to: "a.md")
            let b = folder.write("b", to: "b.md")
            store.noteRecent(a)
            store.noteRecent(b)
            store.noteRecent(a)
            #expect(store.recents.map(\.name) == ["a.md", "b.md"])
            store.clearRecents()
            #expect(store.recents.isEmpty)
        }

        @Test func recentsStopAtFifteen() {
            clear()
            store.clearRecents()
            let folder = TempFolder()
            for index in 0..<20 { store.noteRecent(folder.write("x", to: "\(index).md")) }
            #expect(store.recents.count == 15)
            #expect(store.recents.first?.name == "19.md")
            store.clearRecents()
        }
    }
}

// MARK: - Library

extension FileHandling {
    @Suite("Library")
    struct Library {
        private let library = LibraryModel.shared

        private func open(_ folder: TempFolder) async {
            library.searchText = ""
            library.selectedKeyword = nil
            library.setFolder(folder.url)
            await waitUntil { !library.isScanning && library.root?.url.path == folder.url.path }
        }

        private func rescan() async {
            library.refresh()
            await waitUntil { !library.isScanning }
        }

        private func names() -> [String] { library.root?.allFiles.map(\.name) ?? [] }

        @Test func scanFindsSheetsAndGroups() async {
            let folder = TempFolder()
            folder.write("# One\n\ntwo three", to: "One.md")
            folder.write("x", to: "Group/Inner.markdown")
            folder.write("not a sheet", to: "picture.png")
            folder.write("hidden", to: ".secret.md")
            await open(folder)
            #expect(Set(names()) == ["One", "Inner"])
            let groups = library.root?.children?.filter(\.isFolder).map(\.name)
            #expect(groups == ["Group"])
            #expect(library.root?.children?.first { $0.name == "One" }?.wordCount == 4)
        }

        @Test func groupsComeFirstThenSheetsInNaturalOrder() async {
            let folder = TempFolder()
            folder.write("x", to: "Sheet 10.md")
            folder.write("x", to: "Sheet 2.md")
            folder.write("x", to: "Zed/In.md")
            await open(folder)
            #expect(library.root?.children?.map(\.name) == ["Zed", "Sheet 2", "Sheet 10"])
        }

        @Test func scanLeavesFilesUnchanged() async throws {
            let folder = TempFolder()
            let file = folder.write(bytes: TextFileFormat.bom + Data("a\r\nb".utf8), to: "windows.md")
            await open(folder)
            #expect(try Data(contentsOf: file) == TextFileFormat.bom + Data("a\r\nb".utf8))
        }

        @Test func tagsComeFromTextAndFrontMatter() async {
            let folder = TempFolder()
            folder.write("---\ntags: [front, shared]\n---\n\nBody #inline and #shared", to: "A.md")
            await open(folder)
            #expect(Set(library.root?.allFiles.first?.keywords ?? []) == ["front", "shared", "inline"])
        }

        @Test func tagsPerLine() {
            #expect(LibraryModel.inlineTags(in: "intro\n#work/alpha and #b\n\n#c") == ["work/alpha", "b", "c"])
        }

        @Test func headingsAndIssueNumbersAreNotTags() {
            #expect(LibraryModel.inlineTags(in: "# Heading\n\nIssue #1 and a#b") == [])
        }

        @Test func nestedTagsFormATreeWithCounts() async {
            let folder = TempFolder()
            folder.write("#work/alpha", to: "A.md")
            folder.write("#work/beta #work/alpha", to: "B.md")
            folder.write("#home", to: "C.md")
            await open(folder)
            let tree = library.tagTree
            #expect(tree.map(\.name) == ["home", "work"])
            let work = tree.first { $0.name == "work" }
            #expect(work?.count == 2, "a sheet with two work tags counts once")
            #expect(work?.children?.map(\.name) == ["alpha", "beta"])
            #expect(work?.children?.first?.count == 2)
        }

        @Test func searchMatchesNamesTagsAndText() async {
            let folder = TempFolder()
            folder.write("nothing special", to: "Lakes.md")
            folder.write("#water today", to: "Tagged.md")
            folder.write("The Café opens", to: "Body.md")
            await open(folder)

            library.searchText = "lakes"
            #expect(library.filteredFiles.map(\.name) == ["Lakes"])
            library.searchText = "water"
            #expect(library.filteredFiles.map(\.name) == ["Tagged"])
            library.searchText = "cafe"
            #expect(library.filteredFiles.map(\.name) == ["Body"], "accents and case are ignored")
            library.searchText = "   "
            #expect(library.filteredFiles.count == 3)
            library.searchText = ""
        }

        @Test func tagFilterIncludesNestedTags() async {
            let folder = TempFolder()
            folder.write("#work/alpha", to: "A.md")
            folder.write("#work", to: "B.md")
            folder.write("#workshop", to: "C.md")
            await open(folder)
            library.selectedKeyword = "work"
            #expect(Set(library.filteredFiles.map(\.name)) == ["A", "B"], "workshop isn't under work")
            library.selectedKeyword = nil
        }

        @Test func snippetShowsTheMatchingLine() {
            let node = LibraryNode(url: URL(fileURLWithPath: "/x.md"), name: "x", isFolder: false, children: nil, wordCount: 3, keywords: [],
                                   body: "Title\nThe quick brown fox jumps over the lazy dog, again and again and again and again and again, yes\nEnd", modified: .now)
            #expect(node.snippet(matching: "FOX") == "The quick brown fox jumps over the lazy dog, again and again and again and again and again, yes")
            #expect(node.snippet(matching: "yes")?.hasPrefix("…") == true)
            #expect(node.snippet(matching: "yes")?.hasSuffix("yes") == true)
            #expect(node.snippet(matching: "zebra") == nil)
        }

        @Test func containsMeansInsideTheFolder() async {
            let folder = TempFolder()
            await open(folder)
            #expect(library.contains(folder.url.appending(path: "a/b.md")))
            #expect(!library.contains(URL(fileURLWithPath: folder.url.path + "-other/b.md")), "a similar name isn't inside")
        }

        @Test func newSheetsDoNotOverwrite() async {
            let folder = TempFolder()
            folder.write("precious", to: "Untitled.md")
            await open(folder)
            let second = library.newSheet()
            let third = library.newSheet()
            #expect(second?.lastPathComponent == "Untitled 2.md")
            #expect(third?.lastPathComponent == "Untitled 3.md")
            #expect(folder.read("Untitled.md") == "precious")
        }

        @Test func newSheetGoesInTheChosenGroup() async {
            let folder = TempFolder()
            folder.write("x", to: "Group/In.md")
            await open(folder)
            let sheet = library.newSheet(in: folder.url.appending(path: "Group"))
            #expect(sheet?.path.hasSuffix("/Group/Untitled.md") == true)
        }

        @Test func newGroups() async {
            let folder = TempFolder()
            await open(folder)
            #expect(library.newGroup(named: "Fresh"))
            #expect(folder.exists("Fresh"))
            #expect(!library.newGroup(named: "Fresh"), "an existing group isn't replaced")
        }

        private func node(_ name: String) -> LibraryNode? {
            library.root?.allFiles.first { $0.name == name }
        }

        @Test func renameKeepsTheExtensionAndContents() async throws {
            let folder = TempFolder()
            folder.write("contents", to: "Old.md")
            await open(folder)
            let target = library.rename(try #require(node("Old")), to: "New")
            #expect(target?.lastPathComponent == "New.md")
            #expect(folder.read("New.md") == "contents")
            #expect(!folder.exists("Old.md"))
        }

        @Test func renameKeepsAnOtherMarkdownExtension() async throws {
            let folder = TempFolder()
            folder.write("contents", to: "Old.markdown")
            await open(folder)
            #expect(library.rename(try #require(node("Old")), to: "New")?.lastPathComponent == "New.markdown")
        }

        @Test func renameNeverOverwrites() async throws {
            let folder = TempFolder()
            folder.write("one", to: "One.md")
            folder.write("two", to: "Two.md")
            await open(folder)
            #expect(library.rename(try #require(node("One")), to: "Two") == nil)
            #expect(folder.read("One.md") == "one")
            #expect(folder.read("Two.md") == "two")
        }

        @Test func renameToNothingIsRefused() async throws {
            let folder = TempFolder()
            folder.write("one", to: "One.md")
            await open(folder)
            #expect(library.rename(try #require(node("One")), to: "   ") == nil)
            #expect(folder.exists("One.md"))
        }

        @Test func renameGroupKeepsItsSheets() async throws {
            let folder = TempFolder()
            folder.write("inside", to: "Group/In.md")
            await open(folder)
            let group = try #require(library.root?.children?.first { $0.isFolder })
            #expect(library.rename(group, to: "Renamed") != nil)
            #expect(folder.read("Renamed/In.md") == "inside")
        }

        /// A dot in the new name counts as the extension, so "Notes v1.2" loses ".md" and the
        /// sheet drops out of the library, though the file itself is still in the folder.
        @Test func renameWithADotKeepsItASheet() async throws {
            let folder = TempFolder()
            folder.write("contents", to: "Notes.md")
            await open(folder)
            let target = library.rename(try #require(node("Notes")), to: "Notes v1.2")
            withKnownIssue("A dotted name loses .md") {
                #expect(target?.lastPathComponent == "Notes v1.2.md")
            }
            await rescan()
            withKnownIssue("So the sheet disappears from the library") {
                #expect(names().contains("Notes v1.2"))
            }
            if let target { #expect(FileManager.default.fileExists(atPath: target.path), "the file itself survives") }
        }

        @Test func picksUpFilesAddedElsewhere() async {
            let folder = TempFolder()
            await open(folder)
            #expect(names().isEmpty)
            folder.write("from Finder", to: "Added.md")
            #expect(await waitUntil { names().contains("Added") }, "the folder is being watched")
        }

        @Test func backlinksFindLinkingSheets() async {
            let folder = TempFolder()
            let target = folder.write("x", to: "Target.md")
            folder.write("see [[target]] here", to: "Linker.md")
            folder.write("see [[Target|the target]]", to: "Labelled.md")
            folder.write("no links", to: "Other.md")
            await open(folder)
            #expect(Set(library.backlinks(to: target).map(\.name)) == ["Linker", "Labelled"])
            #expect(library.backlinks(to: nil).isEmpty)
        }

        @Test func completionPrefersNamesThatStartWithTheText() async {
            let folder = TempFolder()
            folder.write("x", to: "A Note.md")
            folder.write("x", to: "Note Two.md")
            folder.write("x", to: "Other.md")
            await open(folder)
            #expect(library.sheetNames(matching: "note") == ["Note Two", "A Note"])
            #expect(library.sheetNames(matching: "").count == 3)
        }

        @Test func wikiLinksResolveInTheLibraryFirst() async {
            let folder = TempFolder()
            let sheet = folder.write("x", to: "Group/Target Sheet.md")
            await open(folder)
            #expect(WikiLinkResolver.resolve("target sheet", near: nil)?.standardizedFileURL == sheet.standardizedFileURL, "case doesn't matter")
            #expect(WikiLinkResolver.resolve("  Target Sheet ", near: nil)?.standardizedFileURL == sheet.standardizedFileURL)
            #expect(WikiLinkResolver.resolve("No Such Sheet", near: nil) == nil)
        }

        @Test func wikiLinksFallBackToTheDocumentsFolder() async {
            let library = TempFolder()
            await open(library)
            let elsewhere = TempFolder()
            let neighbour = elsewhere.write("x", to: "Neighbour.txt")
            let document = elsewhere.url.appending(path: "Doc.md")
            #expect(WikiLinkResolver.resolve("Neighbour", near: document)?.path == neighbour.path)
            #expect(WikiLinkResolver.resolve("Absent", near: document) == nil)
        }
    }
}

// MARK: - Front matter

extension FileHandling {
    @Suite("Front matter")
    struct FrontMatterEditing {
        @Test(arguments: [
            ("---\ntags: [a, b]\n---\nBody", ["a", "b"]),
            ("---\ntags: a, b\n---\nBody", ["a", "b"]),
            ("---\nkeywords: [\"a\", 'b']\n---\nBody", ["a", "b"]),
            ("---\ntags:\n  - a\n  - b\n---\nBody", ["a", "b"]),
            ("---\ntitle: x\n---\nBody", []),
            ("Body only", []),
            ("---\ntags: [a]\nno closing fence", []),
        ])
        func readsKeywords(source: String, expected: [String]) {
            #expect(FrontMatter.keywords(in: source) == expected)
        }

        @Test func addingCreatesTheBlockAndKeepsTheBody() {
            let result = FrontMatter.settingKeywords(["a", "b"], in: "# Title\n\nBody")
            #expect(result == "---\ntags: [a, b]\n---\n\n# Title\n\nBody")
            #expect(FrontMatter.keywords(in: result) == ["a", "b"])
        }

        @Test func changingKeepsOtherEntriesAndBody() {
            let result = FrontMatter.settingKeywords(["new"], in: "---\ntitle: Trip\ntags: [old]\nauthor: Dave\n---\n\nBody text")
            #expect(result.contains("title: Trip"))
            #expect(result.contains("author: Dave"))
            #expect(result.hasSuffix("\n\nBody text"))
            #expect(FrontMatter.keywords(in: result) == ["new"])
        }

        @Test func listFormIsReplacedWhole() {
            let result = FrontMatter.settingKeywords(["x"], in: "---\ntags:\n  - a\n  - b\ntitle: T\n---\nBody")
            #expect(FrontMatter.keywords(in: result) == ["x"])
            #expect(result.contains("title: T"))
            #expect(!result.contains("- a"))
        }

        @Test func removingTheLastRemovesTheBlock() {
            #expect(FrontMatter.settingKeywords([], in: "---\ntags: [a]\n---\n\nBody") == "Body")
        }

        @Test func removingKeepsOtherEntries() {
            let result = FrontMatter.settingKeywords([], in: "---\ntitle: T\ntags: [a]\n---\n\nBody")
            #expect(result == "---\ntitle: T\n---\n\nBody")
        }

        @Test func nothingToDoLeavesTheTextAlone() {
            #expect(FrontMatter.settingKeywords([], in: "Just body") == "Just body")
            #expect(FrontMatter.settingKeywords(["  "], in: "Just body") == "Just body")
        }

        @Test func aRuleLaterInTheTextIsNotFrontMatter() {
            let source = "Intro\n\n---\n\nMore"
            #expect(FrontMatter.keywords(in: source) == [])
            let result = FrontMatter.settingKeywords(["a"], in: source)
            #expect(result.hasSuffix(source), "the body must be untouched")
        }

        @Test func documentKeywordsEditThroughTheDocument() throws {
            let folder = TempFolder()
            let document = try Document.open(url: folder.write("Body", to: "k.md"))
            document.setKeywords(["one"])
            #expect(document.keywords == ["one"])
            #expect(document.hasUnsavedChanges)
            #expect(document.text.hasSuffix("Body"))
        }
    }
}

// MARK: - Goals

extension FileHandling {
    @Suite("Writing goals")
    struct Goals {
        @Test func eachKindOfGoal() {
            var goal = WritingGoal(kind: .words, mode: .atLeast, target: 100)
            #expect(!goal.isMet(current: 99))
            #expect(goal.isMet(current: 100))
            goal.mode = .atMost
            #expect(goal.isMet(current: 100))
            #expect(!goal.isMet(current: 101))
            goal.mode = .about
            #expect(goal.isMet(current: 90))
            #expect(goal.isMet(current: 110))
            #expect(!goal.isMet(current: 89))
        }

        @Test func progressStopsAtFull() {
            let goal = WritingGoal(target: 100)
            #expect(goal.fraction(current: 50) == 0.5)
            #expect(goal.fraction(current: 500) == 1)
            #expect(WritingGoal(target: 0).fraction(current: 10) == 0, "a zero target doesn't divide by zero")
        }

        @Test func countsTheRightThing() {
            let stats = TextStatistics.compute(markdown: "two words")
            #expect(WritingGoal(kind: .words).current(from: stats) == 2)
            #expect(WritingGoal(kind: .characters).current(from: stats) == 9)
        }

        @Test func deadlineCountsCalendarDays() {
            let later = Calendar.current.date(byAdding: .day, value: 3, to: Date())
            #expect(WritingGoal(deadline: later).daysRemaining == 3)
            #expect(WritingGoal(deadline: nil).daysRemaining == nil)
        }

        @Test func goalFollowsTheFileThroughSaveAsAndMove() throws {
            let folder = TempFolder()
            let document = Document(text: "x")
            GoalStore.shared.set(WritingGoal(target: 321), for: document.goalKey)
            let first = folder.url.appending(path: "first.md")
            try document.write(to: first)
            #expect(GoalStore.shared.goal(for: document.goalKey)?.target == 321)

            let second = folder.url.appending(path: "second.md")
            try FileManager.default.moveItem(at: first, to: second)
            document.fileMoved(to: second)
            #expect(GoalStore.shared.goal(for: document.goalKey)?.target == 321)
            GoalStore.shared.set(nil, for: document.goalKey)
        }

        @Test func goalsDoNotClashBetweenUntitledDocuments() {
            TestEnvironment.prepare()
            #expect(Document(text: "a").goalKey != Document(text: "b").goalKey)
        }
    }
}

// MARK: - Quick Open

@Suite("Quick Open matching")
struct QuickOpenTests {
    @Test func lettersInOrderMatch() {
        #expect(QuickOpenView.fuzzyScore("trn", in: "trip notes") != nil, "the guide's own example")
        #expect(QuickOpenView.fuzzyScore("xyz", in: "trip notes") == nil)
        #expect(QuickOpenView.fuzzyScore("ton", in: "note") == nil, "out of order doesn't match")
    }

    @Test func tighterMatchesScoreHigher() throws {
        let adjacent = try #require(QuickOpenView.fuzzyScore("not", in: "notes"))
        let scattered = try #require(QuickOpenView.fuzzyScore("not", in: "nearly out there"))
        #expect(adjacent > scattered)
    }

    @Test func wordStartsScoreHigher() throws {
        let start = try #require(QuickOpenView.fuzzyScore("n", in: "trip notes"))
        let middle = try #require(QuickOpenView.fuzzyScore("n", in: "banana"))
        #expect(start > middle)
    }
}
