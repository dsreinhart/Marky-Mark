//
//  LibraryModel+Mac.swift
//  Markwright
//
//  The Mac's folder window for choosing the library folder.
//

import AppKit

extension LibraryModel {
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder that holds your Markdown library"
        panel.prompt = "Use as Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }
}
