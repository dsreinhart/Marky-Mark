//
//  HelpGuide.swift
//  Markwright
//
//  The bundled user guide. On iPad and iPhone the Mac-specific opening is replaced and their section
//  is moved to the front, since the rest of the guide describes the Mac app.
//

import Foundation

enum HelpGuide {
    static let padIntroduction = """
    Welcome to Markwright on iPad and iPhone. This guide covers both this app and the Mac app it comes with. The first section is about the iPad and iPhone; the numbered sections after it describe the Mac, and most of what they say about writing Markdown applies here too.

    > **Tip:** Tap **Done** to go back to your document. The guide is always in the **More** menu.
    """

    /// The guide with the iPad opening and the iPad section first. Returns the text unchanged
    /// when its layout isn't what this expects.
    static func adaptedForPad(_ guide: String) -> String {
        let lines = guide.components(separatedBy: "\n")
        guard let title = lines.firstIndex(where: { $0.hasPrefix("# ") }),
              let firstRule = lines[(title + 1)...].firstIndex(where: { $0 == "---" }),
              let padStart = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.contains("Markwright for iPad") }) else {
            return guide
        }
        let padEnd = lines[(padStart + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
        guard padStart > firstRule else { return guide }
        var section = Array(lines[padStart..<padEnd])
        // Drop the section number and the rule that closes it, since it moves to the front.
        section[0] = "## Markwright for iPad and iPhone"
        while let last = section.last, last.isEmpty || last == "---" { section.removeLast() }
        var rest = Array(lines[(firstRule + 1)..<padStart]) + Array(lines[padEnd...])
        while let first = rest.first, first.isEmpty { rest.removeFirst() }
        let result = Array(lines[...title]) + [""] + padIntroduction.components(separatedBy: "\n")
            + ["", "---", ""] + section + ["", "---", ""] + rest
        return result.joined(separator: "\n")
    }
}
