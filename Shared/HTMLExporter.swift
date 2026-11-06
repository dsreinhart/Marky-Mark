//
//  HTMLExporter.swift
//  Marky Mark
//
//  Markdown → standalone HTML with a choice of style templates. Used for the
//  export preview, HTML/PDF/Word export and printing.
//

import Foundation

enum ExportStyle: String, CaseIterable, Identifiable {
    case clean, classic, modern, manuscript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clean: return "Clean"
        case .classic: return "Classic"
        case .modern: return "Modern"
        case .manuscript: return "Manuscript"
        }
    }

    var css: String {
        let shared = """
        * { box-sizing: border-box; }
        body { margin: 0 auto; padding: 48px 32px; color: #1d1d1f; background: #fff; -webkit-text-size-adjust: 100%; }
        img { max-width: 100%; height: auto; }
        pre { background: #f4f4f6; border: 1px solid #e2e2e6; border-radius: 6px; padding: 12px 14px; overflow-x: auto; font-size: 0.9em; }
        code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.92em; }
        p code, li code, td code { background: #f1f1f4; padding: 1px 4px; border-radius: 3px; }
        blockquote { margin: 1.2em 0; padding: 0.2em 1.2em; border-left: 3px solid #c9c9ce; color: #4a4a4f; }
        table { border-collapse: collapse; width: 100%; margin: 1.2em 0; }
        th, td { border: 1px solid #d9d9de; padding: 6px 10px; text-align: left; vertical-align: top; }
        th { background: #f4f4f6; }
        hr { border: 0; border-top: 1px solid #d9d9de; margin: 2em 0; }
        li.task { list-style: none; margin-left: -1.4em; }
        li.task input { margin-right: 0.5em; }
        a { color: #0a5bd8; }
        mark { background: #fff2a8; padding: 0 2px; border-radius: 2px; }
        .tag { color: #0a5bd8; background: rgba(10,91,216,0.08); padding: 0 5px; border-radius: 10px; font-size: 0.92em; }
        a.wikilink { text-decoration: none; border-bottom: 1px dotted #0a5bd8; }
        sup.fnref { font-size: 0.75em; line-height: 0; }
        sup.fnref a { text-decoration: none; }
        section.footnotes { margin-top: 2.5em; font-size: 0.9em; color: #4a4a4f; }
        section.footnotes ol { padding-left: 1.4em; }
        section.footnotes li { margin: 0.3em 0; }
        @media print { body { padding: 0; } a { color: inherit; text-decoration: none; } pre, blockquote, table, img { break-inside: avoid; } h1, h2, h3 { break-after: avoid; } }
        """
        switch self {
        case .clean:
            return shared + """
            body { font-family: -apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 17px; line-height: 1.6; max-width: 46em; }
            h1, h2, h3, h4, h5, h6 { font-weight: 700; line-height: 1.25; margin: 1.6em 0 0.5em; letter-spacing: -0.01em; }
            h1 { font-size: 2.1em; margin-top: 0; } h2 { font-size: 1.6em; border-bottom: 1px solid #e5e5ea; padding-bottom: 0.2em; } h3 { font-size: 1.25em; }
            """
        case .classic:
            return shared + """
            body { font-family: Georgia, "Iowan Old Style", "Times New Roman", serif; font-size: 18px; line-height: 1.65; max-width: 40em; }
            h1, h2, h3, h4, h5, h6 { font-family: Georgia, serif; font-weight: 700; margin: 1.5em 0 0.5em; }
            h1 { font-size: 2.2em; text-align: center; margin-top: 0; } h2 { font-size: 1.5em; } h3 { font-size: 1.2em; font-style: italic; font-weight: 400; }
            p { text-align: justify; hyphens: auto; }
            blockquote { font-style: italic; }
            """
        case .modern:
            return shared + """
            body { font-family: "Helvetica Neue", "Avenir Next", Helvetica, Arial, sans-serif; font-size: 16px; line-height: 1.7; max-width: 52em; color: #222; }
            h1, h2, h3, h4, h5, h6 { font-weight: 600; margin: 2em 0 0.6em; text-transform: none; letter-spacing: 0.01em; }
            h1 { font-size: 2.4em; font-weight: 300; margin-top: 0; } h2 { font-size: 1.4em; color: #0a5bd8; } h3 { font-size: 1.1em; text-transform: uppercase; letter-spacing: 0.08em; color: #555; }
            blockquote { border-left-color: #0a5bd8; }
            """
        case .manuscript:
            return shared + """
            body { font-family: "Courier New", Courier, ui-monospace, monospace; font-size: 12pt; line-height: 2; max-width: 6.5in; }
            h1, h2, h3, h4, h5, h6 { font-size: 12pt; font-weight: 700; text-align: center; margin: 2em 0 1em; text-transform: uppercase; }
            p { text-indent: 0.5in; margin: 0; }
            p:first-of-type, h1 + p, h2 + p, h3 + p { text-indent: 0; }
            pre, code { font-family: inherit; }
            """
        }
    }
}

@MainActor
enum HTMLExporter {

    /// A complete HTML document.
    static func document(markdown: String, title: String, style: ExportStyle) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(style.css)
        </style>
        </head>
        <body>
        \(body(markdown: markdown))
        </body>
        </html>
        """
    }

    /// Just the content markup (no html/head wrapper).
    static func body(markdown: String) -> String {
        var out = ""
        var lists: [(tag: String, indent: Int)] = []
        var footnotes: [(id: String, html: String)] = []

        func closeLists(deeperThan indent: Int?) {
            while let top = lists.last, indent == nil || top.indent > indent! {
                out += "</li>\n</\(top.tag)>\n"
                lists.removeLast()
            }
        }

        func listItem(tag: String, indent: Int, content: String, cssClass: String? = nil) {
            closeLists(deeperThan: indent)
            if let top = lists.last, top.indent == indent {
                if top.tag == tag {
                    out += "</li>\n"
                } else {
                    out += "</li>\n</\(top.tag)>\n<\(tag)>\n"
                    lists[lists.count - 1] = (tag, indent)
                }
            } else {
                out += "<\(tag)>\n"
                lists.append((tag, indent))
            }
            out += cssClass.map { "<li class=\"\($0)\">" } ?? "<li>"
            out += content
        }

        for block in MarkdownParser.parse(markdown) {
            switch block {
            case .unorderedListItem(let text, let indent):
                listItem(tag: "ul", indent: indent, content: inline(text))
                continue
            case .orderedListItem(_, let text, let indent):
                listItem(tag: "ol", indent: indent, content: inline(text))
                continue
            case .taskListItem(let checked, let text, let indent):
                let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")>"
                listItem(tag: "ul", indent: indent, content: box + inline(text), cssClass: "task")
                continue
            default:
                closeLists(deeperThan: nil)
            }

            switch block {
            case .heading(let level, let text):
                let tag = "h\(min(max(level, 1), 6))"
                out += "<\(tag)>\(inline(text))</\(tag)>\n"
            case .paragraph(let text):
                out += "<p>\(inline(text))</p>\n"
            case .codeBlock(let language, let code):
                let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                out += "<pre><code\(cls)>\(escape(code))</code></pre>\n"
            case .blockquote(let text):
                let lines = text.components(separatedBy: "\n").map(inline).joined(separator: "<br>\n")
                out += "<blockquote><p>\(lines)</p></blockquote>\n"
            case .horizontalRule:
                out += "<hr>\n"
            case .table(let headers, let rows):
                out += "<table>\n<thead><tr>" + headers.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                for row in rows {
                    out += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                }
                out += "</tbody>\n</table>\n"
            case .footnoteDefinition(let id, let text):
                footnotes.append((id, inline(text)))
            case .blank, .comment, .frontMatter, .unorderedListItem, .orderedListItem, .taskListItem:
                break
            }
        }
        closeLists(deeperThan: nil)
        if !footnotes.isEmpty {
            out += "<section class=\"footnotes\">\n<hr>\n<ol>\n"
            for note in footnotes {
                let id = escapeAttribute(note.id)
                out += "<li id=\"fn-\(id)\">\(note.html) <a href=\"#fnref-\(id)\" class=\"fnback\">\u{21A9}</a></li>\n"
            }
            out += "</ol>\n</section>\n"
        }
        return out
    }

    static func inline(_ markdown: String) -> String {
        render(InlineParser.parse(markdown))
    }

    private static func render(_ nodes: [InlineNode]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s): out += escape(s)
            case .code(let s): out += "<code>\(escape(s))</code>"
            case .emphasis(let kids): out += "<em>\(render(kids))</em>"
            case .strong(let kids): out += "<strong>\(render(kids))</strong>"
            case .strike(let kids): out += "<del>\(render(kids))</del>"
            case .link(let label, let url): out += "<a href=\"\(escapeAttribute(url))\">\(render(label))</a>"
            case .image(let alt, let source): out += "<img src=\"\(escapeAttribute(source))\" alt=\"\(escapeAttribute(alt))\">"
            case .highlight(let kids): out += "<mark>\(render(kids))</mark>"
            case .tag(let name): out += "<span class=\"tag\">#\(escape(name))</span>"
            case .wikiLink(let target, let label):
                out += "<a class=\"wikilink\" href=\"\(escapeAttribute(target)).html\">\(escape(label ?? target))</a>"
            case .footnoteRef(let id):
                let safe = escapeAttribute(id)
                out += "<sup class=\"fnref\" id=\"fnref-\(safe)\"><a href=\"#fn-\(safe)\">\(escape(id))</a></sup>"
            }
        }
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
