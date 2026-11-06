# Markwright Help

Welcome to Markwright, a Markdown editor for the Mac with a companion app for iPad. This guide covers everything the app does. It is itself a Markdown document, so what you see here is the formatted editor at work: click anywhere and type to try things out. Nothing you change here affects the original: close this tab and choose **Help > Markwright Help** to get a fresh copy.

> **Tip:** Switch between this guide and your own documents with the tab bar at the top of the window. Press **⌘?** at any time to bring the guide back.

---

## 1. The basics

### Raw, Dual and Formatted

Every document can be shown three ways. Switch between them with the **Raw / Dual / Formatted** control in the window toolbar; the status bar at the bottom of the window shows which one is active.

- **Raw** shows the Markdown source with syntax highlighting. You type the markup yourself. The Format menu still works here: it inserts or removes the Markdown syntax around the selection.
- **Formatted** shows the formatted document and lets you edit it directly, like a word processor. Headings, lists, tables, checkboxes and images are live, and the toolbar and Format menu apply styles to the selection.
- **Dual** shows both side by side, source on the left and formatted on the right. You can type in either one.

All three describe the same text. The file on disk is plain Markdown, so it opens in any other editor. Markwright remembers which one you used last and opens new windows the same way. Switching keeps your place: the new view opens at the same spot in the document with your selection carried across.

### Working in Dual

- **The panes scroll together.** Scroll either one and the other follows, block by block. Both reach the top and the end of the document at the same time.
- **Edits appear in the other pane.** The pane you are typing in responds immediately. The other one catches up as soon as you pause, or as soon as you click into it.
- **Formatting follows the cursor.** The toolbar and Format menu act on whichever pane holds the cursor. In the raw pane they insert Markdown syntax. Folding and indent buttons only act in the formatted pane.
- **Jumps show in both.** A library search result, the previous and next match buttons, a footnote jump and a tag jump select and flash the place in both panes.
- **Undo belongs to each pane.** ⌘Z undoes your typing in the pane holding the cursor. Editing in one pane clears the other pane's undo history, because the text it remembers has changed.
- **Find** (⌘F) opens a separate find bar in the pane holding the cursor, and the other pane follows by scrolling.
- **Focus Mode and Typewriter Scrolling** apply to the pane holding the cursor.

### Windows and tabs

Each document is a tab. Opening another file adds a tab to the current window; drag a tab out to give it its own window, or use the Window menu to merge windows again. **⌘W** closes a tab.

### The status bar

The strip along the bottom of the window shows the active editor, whether Focus Mode or Typewriter Scrolling is on, your writing goal progress, and the live word count, character count and estimated reading time. Comments and front matter are left out of the counts.

### The sample and this guide

The first time Markwright launches it opens this guide. Later launches reopen whatever you had open when you quit, including unsaved untitled drafts.

---

## 2. Writing and formatting

### The toolbar

The formatting toolbar sits above the text. Hover over any button for its name and shortcut. From left to right it offers bold, italic, strikethrough, inline code, highlight, link, image and footnote; bulleted, numbered and task lists; blockquote, code block and comment; horizontal rule and table; indent and outdent; and fold.

A button lights up when the text at the cursor already has that style. Clicking it again removes the style.

### Inline styles

| Style | Shortcut | Markdown |
|---|---|---|
| **Bold** | ⌘B | `**text**` |
| *Italic* | ⌘I | `*text*` |
| ~~Strikethrough~~ | ⌘⇧X | `~~text~~` |
| `Inline code` | ⌘E | `` `text` `` |
| ==Highlight== | ⌘⇧H | `==text==` |
| Link | ⌘K | `[label](https://example.com)` |
| Footnote | ⌥⇧⌘F | `[^1]` with a `[^1]:` definition |

Select some text and press the shortcut to wrap it. With nothing selected the style applies to what you type next (formatted view) or inserts the markers with the cursor between them (raw editor).

**Links:** ⌘K opens a small panel for the address and label. In the formatted view click a link to open it in your browser. If the cursor is already in a link, ⌘K removes it.

**Footnotes:** the footnote command inserts the next free reference number after the selection and adds a matching definition at the end of the document, with the cursor ready for you to type the note. Here is one in action.[^1] In the formatted view click the small number to jump to its definition, and click the number at the start of the definition to come back. In the raw view do the same with ⌘-click on `[^1]`.

### Paragraph styles

| Style | Shortcut | Markdown |
|---|---|---|
| Paragraph | ⌘0 | plain text |
| Heading 1 to 6 | ⌘1 to ⌘6 | `#` to `######` followed by a space |
| Bulleted list | ⌘⇧8 | `- item` |
| Numbered list | ⌘⇧7 | `1. item` |
| Task list | ⌘⇧9 | `- [ ] todo` and `- [x] done` |
| Blockquote | ⌘⇧. | `> quote` |
| Code block | ⌘⇧C | three backticks, optional language, three backticks |
| Comment | ⌘⇧/ | `<!-- note to self -->` |
| Increase indent | ⌘] | two extra spaces before a list item |
| Decrease indent | ⌘[ | |

Each of these toggles: apply a heading to a heading of the same level and it becomes a paragraph again.

**Headings** need a space after the hash marks. `# Title` is a heading, while `#title` with no space is a tag (see section 6).

### Lists

In the formatted view lists behave as you would expect:

- Press **Return** at the end of an item to start the next one. Numbered lists renumber themselves.
- Press **Return** on an empty item to end the list.
- Press **Tab** or **⇧Tab** on an item to nest or unnest it. ⌘] and ⌘[ do the same.
- Click a task checkbox to tick or untick it. Checked items are written as `- [x]`.

### Tables

**Format > Table…** inserts a table of the size you choose. In the formatted view you edit cells in place: **Tab** moves to the next cell, **⇧Tab** to the previous one and **Return** to the next row. Tables are written in the standard pipe syntax, so they stay readable in the raw view.

| Column | Another | Notes |
|---|---|---|
| Edit me | Tab moves right | Return moves down |

### Images

**Format > Image…** (or the toolbar button) asks for an image file and an alt text. If the image lives inside the document's folder it is stored with a relative path, so the document keeps working when the folder moves. Images show inline at their natural size, left-aligned. In the raw editor the command inserts an image placeholder for you to fill in.

Exports embed local images into the output, so an exported HTML or PDF file stands alone (section 10).

### Code blocks

A code block keeps your text exactly as typed in a monospaced font. Add a language name after the opening backticks for your own reference:

```swift
struct Greeting: View {
    var body: some View { Text("Hello, Markwright!") }
}
```

### Comments

A comment is a note to yourself that stays in the file but never reaches an export, the word count or the reading time. Comments use the HTML comment syntax, so other Markdown tools also hide them:

```markdown
<!-- Remember to check this date before publishing. -->
```

### Folding sections

In the formatted view you can collapse the body of a heading to see the document's structure. Put the cursor on a heading and press **⌥⌘←** (or use the toolbar's fold button); press it again to expand. **Format > Unfold All Sections** (⌥⇧⌘→) opens everything. Typing into a folded section unfolds it automatically. Folding is a view setting only; the file is never changed by it.

### Find, replace, spelling

**Edit > Find** (⌘F) opens the standard find bar in either editor; **⌥⌘F** adds replace, **⌘G** finds the next match. **Edit > Spelling and Grammar** offers the usual macOS checking, including grammar and automatic correction, and the choices stick.

### The cheat sheet

The **Cheat Sheet** toolbar button opens a quick reference of every Markdown construct the app understands, with its syntax and result side by side.

---

## 3. Markdown reference

Markwright reads and writes standard Markdown plus a few widely used extensions. Everything the app renders is listed here.

### Block elements

```markdown
# Heading 1 … ###### Heading 6

A paragraph is one or more lines of text separated from the next paragraph by a blank line.

- Bulleted item (also * or +)
  - Nested item (indent two spaces)
1. Numbered item
- [ ] Open task
- [x] Finished task

> A blockquote. Consecutive > lines merge into one quote.

---            (horizontal rule; *** and ___ work too)

| Header | Header |
|--------|--------|
| cell   | cell   |

<!-- a comment -->

[^1]: A footnote definition, usually at the end.
```

Code blocks are fenced with three backticks on their own lines.

### Inline elements

```markdown
**bold**  *italic*  ***both***  ~~struck~~  `code`  ==highlight==
[link text](https://example.com)
![alt text](picture.png)
A sentence with a footnote reference.[^1]
[[Another Sheet]]        (wiki link, section 5)
#tag  #project/subtopic  (tags, section 6)
```

### Front matter

A block between two `---` lines at the very top of a file is treated as metadata, kept out of the rendered text and the counts. Markwright reads `tags:` or `keywords:` from it to feed the library and the dashboard, either as a comma-separated list or as a YAML list:

```yaml
---
title: Trip notes
tags: travel, planning
---
```

### What is left as written

Anything Markwright does not render, such as raw HTML other than comments, is preserved in the file exactly as written and shown as plain text.

---

## 4. Files

### New, open, save

| Command | Shortcut | What it does |
|---|---|---|
| File > New | ⌘N | A new untitled document in a new tab. It lives in memory until you save it. |
| File > New Sheet in Library | ⌥⌘N | Creates `Untitled.md` in your library folder and opens it. It is a real file from the start. |
| File > Open… | ⌘O | Opens Markdown or plain-text files, each in its own tab. |
| File > Open Recent | | The last fifteen files, with Clear Menu at the bottom. |
| File > Quick Open… | ⌘⇧O | Type part of a name to jump to any library sheet or open tab (section 5). |
| File > Save | ⌘S | Saves now. Titled documents also save on their own, see below. |
| File > Save As… | ⌘⇧S | Saves a copy under a new name and switches the tab to it. |
| File > Close | ⌘W | Closes the tab. |
| File > Split at Cursor | ⌘⇧D | Moves everything after the cursor into a new untitled document. |

You can also open files by double-clicking them in Finder, dragging them onto the Markwright icon, or choosing Markwright from Finder's **Open With** menu.

### Autosave

A document that has a file saves itself about a second and a half after you stop typing, and again when you switch apps, close a tab or quit. You never need to press ⌘S, though you can. Untitled documents are kept as drafts and restored on the next launch; closing one asks whether to save it.

If a file can no longer be written (for example its folder was removed), Markwright tells you and offers Save As.

### Versions

**File > Save a Version** (⌥⌘S) snapshots the current text. **File > Revert To** lists **Last Opened**, which restores the text as it was when you opened the file this session, followed by every saved version by date. Up to fifty versions are kept per file. Versions are stored in Markwright's own support folder, not beside your documents, and the file on disk is untouched until you revert.

### Line endings, encodings and the byte-order mark

Markwright keeps files the way it found them. A file saved with Windows (CRLF) or classic Mac (CR) line endings, or with a UTF-8 byte-order mark, is written back the same way. Files that are not valid UTF-8 are read as Windows-1252 so nothing is lost, and new files are written as UTF-8 with Unix line endings.

### Making Markwright the default Markdown app

**Markwright > Settings… > Files** shows which app currently opens `.md` files and offers one button to make Markwright the default. Markwright also appears in Finder's Open With menu for Markdown and plain-text files without changing the default.

---

## 5. The Library

The library is a sidebar that shows one folder of Markdown files, in the style of Ulysses. Show or hide it with the toolbar button or **View > Show Library** (⌥⌘L).

### Choosing a folder

The first time you open the sidebar, click **Choose Folder…** and pick any folder, for example one in iCloud Drive so your iPad sees it too. Its Markdown files become **sheets** and its subfolders become **groups**. You can change the folder later from the **•••** menu at the top of the sidebar. The sidebar's header shows the folder's name.

Markwright watches the folder, so files added, renamed or deleted in Finder or by another app appear within a moment. **Refresh** in the ••• menu forces a rescan.

### Working with sheets

- **Click** a sheet to open it in the current tab, or choose **Open in New Tab** from its context menu.
- Each row shows the sheet's word count. Groups show how many sheets they contain.
- **Right-click** a sheet or group for **New Sheet in Group**, **Open in New Tab**, **Rename…**, **Reveal in Finder** and **Move to Trash**. Renaming a sheet renames the file; moving one to the Trash uses the Finder Trash so it can be recovered.
- The ••• menu also offers **New Sheet**, **New Group…**, **Choose Library Folder…** and **Reveal in Finder**.

### Searching

The search field at the top filters the list as you type. It matches sheet names, keywords and tags, and the text inside every sheet. A sheet matched by its text shows the matching line underneath its name. A line above the list says how many sheets match and why. Click the clear button in the field to see everything again.

Clicking a result opens the sheet, jumps to the first match and flashes it. While a search is active and the sheet on screen contains the term, the sidebar shows how many matches it has, with **▲** and **▼** buttons to move to the previous and next one. **⌘G** and **⌘⇧G** step through them too.

Documents open in tabs that are not in the library, such as this guide, are searched as well and appear under **Open Tabs**.

### The Tags section

Below the sheets, the **Tags** section lists every tag used anywhere in the folder, with a count of the sheets carrying it. Nested tags such as `#project/alpha` appear as a tree you can expand. Click a tag to show only the sheets that use it (selecting a parent includes all its children); click it again, or the **Clear** button, to remove the filter. Hover over a tag for an explanation.

### Quick Open

Press **⌘⇧O**, type a few letters of a name and press Return. Matching is fuzzy, so `trn` finds "Trip notes". It searches the library and every open tab, and the best match is selected first.

---

## 6. Linking and tagging

### Wiki links

Type `[[` and the name of another sheet, then `]]`, and the text becomes a link to that sheet: for example `[[Meeting notes]]`. While you type inside the brackets Markwright suggests matching sheet names from the library; press Return to accept one, and the closing brackets are added for you.

Clicking a wiki link opens the sheet in a new tab. If no sheet has that name, Markwright offers to create it in the library folder (or beside the current document when no library is set) with the name as its first heading. Names are matched without regard to case, first across the library and then in the document's own folder.

### Backlinks

The dashboard's **Backlinks** section lists every sheet that links to the current one, including unsaved tabs. Click an entry to open it. The **Images & Links** section lists the outgoing links from the current document, wiki links included.

### Tags

A word starting with `#` and followed directly by letters is a tag, such as `#draft` or `#work`. A heading needs a space after the `#`, so there is no ambiguity. Tags can be nested with slashes: `#project/alpha` is the tag "alpha" inside "project". You only ever type the full path; the library builds the tree from it.

Tags come from two places and are treated the same way:

1. **Inline** anywhere in the text, as above.
2. **Front matter** `tags:` or `keywords:` lines at the top of the file (section 3).

The dashboard's **Keywords** section shows the current document's tags. Click one to jump to its next occurrence in the text; right-click for **Jump to Tag** or **Filter Library by Tag**. The **Add keyword…** field writes a new keyword into the front matter, creating the block if needed.

Here is a live example you can click in the dashboard: #example and #help/guide.

---

## 7. The Dashboard

The dashboard is the right-hand sidebar: **View > Show Dashboard** (⌥⌘D) or the toolbar button.

- **Statistics**: words, characters with and without spaces, sentences, paragraphs and reading time, all computed from the body text without comments or front matter.
- **Goal**: a word or character target for this document, of the kind *at least*, *at most* or *about*, with an optional deadline. Progress shows here and in the status bar, turning green when met. Goals are stored per file.
- **Outline**: every heading with its level. Click one to scroll to it.
- **Keywords**: the document's tags (section 6).
- **Images & Links**: every image, link and wiki link in the document.
- **Backlinks**: sheets that link here (section 6).

---

## 8. The writing environment

- **Typewriter Scrolling** (⌥⌘T, View menu) keeps the line you are typing at a fixed height in the window so your eyes never travel down the screen.
- **Focus Mode** (View menu) dims everything except the current **Paragraph** or **Sentence**.
- **Composition Mode** (⌥⌘C) hides the toolbar, both sidebars and the window chrome, and narrows the text column so only your writing is left. Press it again, or leave full screen, to come back.
- **Editor width** (Settings > Editor) limits the text column to narrow, comfortable or wide measures, or lets it fill the window.

All of these work in every view and are remembered between launches.

---

## 9. Appearance

**Markwright > Settings…** (⌘,) has four tabs.

- **Editor**: a theme to start from (Default, Sepia, Paper, Graphite, Solarized or Typewriter), optional custom editor background and text colors, the editor font (system, serif, rounded, monospaced and a few classics such as Georgia and Palatino), line spacing and editor width.
- **Colors**: fine control over heading, link, blockquote, code, strikethrough, checked-task and table-header colors, dividers under H1 and H2, and italic quotes. **Reset All to Defaults** undoes everything.
- **Typography**: the body text size, with a live preview of headings, quotes and code.
- **Files**: the default app for Markdown files (section 4).

Settings apply to every window immediately. The iPad app has the same settings screen of its own.

---

## 10. Export and print

**File > Export Preview…** (⌘⇧E) shows the document as it will export, in one of eight styles:

- **Clean**, the default: a plain modern look in the system font.
- **Classic**: Georgia serif with justified text and italic quotes.
- **Modern**: a light sans-serif with blue accents.
- **Book**: an old-style serif with indented, justified paragraphs and centred headings.
- **Report**: a business look with navy headings and shaded tables.
- **Academic**: Times New Roman at 12 points and 1.5 line spacing, with ruled tables.
- **Technical**: documentation-style headings with clearly marked code blocks and tables.
- **Manuscript**: Courier at 12 points, double spaced, with indented paragraphs.

These are ready-made looks, not formal standards. Academic doesn't apply APA or MLA rules, and Manuscript has no title page or running header, so check any submission against its own requirements. Markwright remembers the style you last picked.

 From the preview, or directly from **File > Export**, you can produce:

- **HTML**, a single file with its styles inline.
- **PDF**, paginated from the same styled HTML.
- **Word (.docx)** and **Rich Text (.rtf)** for people who edit in other apps.
- **Copy as HTML** puts the HTML on the clipboard for pasting into a web editor or mail message.

**File > Print…** (⌘P) prints the styled document.

Images stored on your Mac are embedded in HTML and PDF output (up to 30 MB each), so the exported file stands alone. Web images are referenced by their address. Comments and front matter never appear in exports; footnotes are collected at the end with return links.

---

## 11. Keyboard shortcuts

| Shortcut | Command |
|---|---|
| ⌘N | New document |
| ⌥⌘N | New sheet in library |
| ⌘O | Open |
| ⌘⇧O | Quick Open |
| ⌘S / ⌘⇧S | Save / Save As |
| ⌥⌘S | Save a Version |
| ⌘⇧D | Split at Cursor |
| ⌘⇧E | Export Preview |
| ⌘P | Print |
| ⌘W | Close tab |
| ⌘B / ⌘I / ⌘⇧X | Bold / Italic / Strikethrough |
| ⌘E / ⌘⇧H | Inline code / Highlight |
| ⌘K | Link |
| ⌥⇧⌘F | Footnote |
| ⌘0 to ⌘6 | Paragraph, Heading 1 to 6 |
| ⌘⇧8 / ⌘⇧7 / ⌘⇧9 | Bulleted / Numbered / Task list |
| ⌘⇧. / ⌘⇧C / ⌘⇧/ | Blockquote / Code block / Comment |
| ⌘] / ⌘[ | Indent / Outdent |
| ⌥⌘← | Fold or unfold section |
| ⌥⇧⌘→ | Unfold all |
| ⌘F / ⌥⌘F / ⌘G | Find / Find and Replace / Find Next |
| ⌥⌘T | Typewriter Scrolling |
| ⌥⌘C | Composition Mode |
| ⌥⌘L / ⌥⌘D | Show Library / Show Dashboard |
| ⌘, | Settings |
| ⌘? | This guide |

---

## 12. Markwright for iPad

The iPad app opens Markdown files from the Files app and iCloud Drive, so a library folder kept in iCloud Drive is shared between the two. It offers a syntax-highlighted editor with the same formatting toolbar, a live rendered preview beside it (**Editor**, **Split** or **Preview**), the dashboard, typewriter scrolling, the same themes and fonts, the cheat sheet, this guide, and HTML, PDF and RTF export with printing from the **More** menu. Images picked on iPad are saved beside the document when its folder has been opened once, and embedded in the text otherwise.

Not yet on iPad: the editable formatted view, focus and composition modes, the library sidebar, versions and Word export.

---

## 13. Where things live

- **Your documents** stay wherever you saved them; Markwright never moves or copies them.
- **Versions, drafts, goals and this guide** are kept in Markwright's own Application Support folder inside its sandbox container, never beside your documents.
- **Settings and the recent-files list** are in the app's preferences.

If a document ever looks wrong, switch to the raw editor: it shows exactly what is in the file.

[^1]: Footnote definitions collect at the end of the document and are numbered in order of appearance.
