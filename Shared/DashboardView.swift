//
//  DashboardView.swift
//  Markwright
//
//  Right-hand inspector: statistics, writing goal, outline, keywords, attachments.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

struct BacklinkEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: URL { url }
}

struct DashboardView: View {
    @Binding var text: String
    let goalKey: String
    let fileURL: URL?
    let onJumpToHeading: (Int) -> Void
    /// Sheets that link here; nil hides the section (no library on this platform).
    let backlinks: [BacklinkEntry]?
    let onOpenBacklink: (URL) -> Void
    /// Follows a `[[wiki link]]` from the Links list.
    let onOpenWikiLink: ((String) -> Void)?
    /// Filters the library by a tag (Mac): keyword chips on click, inline tags from their context menu.
    let onSelectTag: ((String) -> Void)?
    /// Moves the cursor to the next `#tag` in the text when an inline tag chip is clicked.
    let onJumpToTag: ((String) -> Void)?

    @State private var showGoalEditor = false
    @State private var newKeyword = ""
    private var goalStore = GoalStore.shared

    init(text: Binding<String>, goalKey: String, fileURL: URL?, onJumpToHeading: @escaping (Int) -> Void,
         backlinks: [BacklinkEntry]? = nil, onOpenBacklink: @escaping (URL) -> Void = { _ in },
         onOpenWikiLink: ((String) -> Void)? = nil, onSelectTag: ((String) -> Void)? = nil,
         onJumpToTag: ((String) -> Void)? = nil) {
        _text = text
        self.goalKey = goalKey
        self.fileURL = fileURL
        self.onJumpToHeading = onJumpToHeading
        self.backlinks = backlinks
        self.onOpenBacklink = onOpenBacklink
        self.onOpenWikiLink = onOpenWikiLink
        self.onSelectTag = onSelectTag
        self.onJumpToTag = onJumpToTag
    }

    private var stats: TextStatistics { TextStatistics.compute(markdown: text) }
    private var keywords: [String] { FrontMatter.keywords(in: text) }

    private func setKeywords(_ keywords: [String]) {
        text = FrontMatter.settingKeywords(keywords, in: text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statisticsSection
                goalSection
                outlineSection
                keywordsSection
                if backlinks != nil { backlinksSection }
                attachmentsSection
            }
            .padding(14)
        }
        .background(Color(platform: .mmWindowBackground))
    }

    // MARK: - Statistics

    private var statisticsSection: some View {
        let stats = self.stats
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Statistics")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(value: stats.words, label: "Words")
                StatTile(value: stats.characters, label: "Characters")
                StatTile(value: stats.sentences, label: "Sentences")
                StatTile(value: stats.paragraphs, label: "Paragraphs")
                StatTile(value: stats.readingMinutes, label: stats.readingMinutes == 1 ? "Minute to read" : "Minutes to read")
                StatTile(value: stats.charactersNoSpaces, label: "Chars, no spaces")
            }
        }
    }

    // MARK: - Goal

    private var goalSection: some View {
        let stats = self.stats
        let goal = goalStore.goal(for: goalKey)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Goal")
                Spacer()
                Button(goal == nil ? "Set…" : "Edit…") { showGoalEditor = true }
                    .controlSize(.small)
                    .popover(isPresented: $showGoalEditor, arrowEdge: .bottom) {
                        GoalEditor(goal: goal) { updated in
                            goalStore.set(updated, for: goalKey)
                            showGoalEditor = false
                        }
                    }
            }
            if let goal {
                let current = goal.current(from: stats)
                let met = goal.isMet(current: current)
                ProgressView(value: goal.fraction(current: current))
                    .tint(met ? .green : (goal.mode == .atMost && current > goal.target ? .red : .accentColor))
                HStack {
                    Text("\(current.formatted()) / \(goal.target.formatted()) \(goal.kind.label.lowercased())")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Text(met ? "Done" : "\(Int(goal.fraction(current: current) * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(met ? .green : .secondary)
                }
                Text(goalSummary(goal, current: current))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Set a word or character target, with an optional deadline, to track this document's progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func goalSummary(_ goal: WritingGoal, current: Int) -> String {
        var parts: [String] = []
        switch goal.mode {
        case .atLeast:
            let remaining = max(goal.target - current, 0)
            parts.append(remaining == 0 ? "Target reached." : "\(remaining.formatted()) to go.")
        case .atMost:
            let over = current - goal.target
            parts.append(over > 0 ? "\(over.formatted()) over the limit." : "\((-over).formatted()) left before the limit.")
        case .about:
            parts.append(goal.isMet(current: current) ? "Within range." : "Aim for roughly \(goal.target.formatted()).")
        }
        if let days = goal.daysRemaining, let deadline = goal.deadline {
            if days < 0 {
                parts.append("Deadline passed \(deadline.formatted(date: .abbreviated, time: .omitted)).")
            } else if days == 0 {
                parts.append("Due today.")
            } else {
                let remaining = max(goal.target - current, 0)
                let pace = Int((Double(remaining) / Double(days)).rounded(.up))
                parts.append("\(days) day\(days == 1 ? "" : "s") left" + (goal.mode == .atLeast && remaining > 0 ? ", about \(pace.formatted()) per day." : "."))
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Outline

    private var outlineSection: some View {
        let entries = TextStatistics.outline(markdown: text)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Outline")
            if entries.isEmpty {
                Text("Headings will appear here.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    Button {
                        onJumpToHeading(entry.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("H\(entry.level)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)
                            Text(entry.text)
                                .font(entry.level <= 2 ? .callout.weight(.semibold) : .callout)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, CGFloat(max(entry.level - 1, 0)) * 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Keywords

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Keywords")
            if !keywords.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(keywords, id: \.self) { keyword in
                        KeywordChip(text: keyword, onTap: onSelectTag.map { select in { select(keyword) } }) {
                            setKeywords(keywords.filter { $0 != keyword })
                        }
                    }
                }
            }
            let inlineTags = TextStatistics.inlineTags(markdown: text).filter { !keywords.contains($0) }
            if !inlineTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(inlineTags, id: \.self) { tag in
                        KeywordChip(text: "#" + tag, onTap: (onJumpToTag ?? onSelectTag).map { act in { act(tag) } })
                            .contextMenu {
                                if let onJumpToTag { Button("Jump to Tag") { onJumpToTag(tag) } }
                                if let onSelectTag { Button("Filter Library by Tag") { onSelectTag(tag) } }
                            }
                    }
                }
            }
            TextField("Add keyword…", text: $newKeyword)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    let value = newKeyword.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { return }
                    if !keywords.contains(value) { setKeywords(keywords + [value]) }
                    newKeyword = ""
                }
            Text(tagHelp)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Backlinks

    private var backlinksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Backlinks")
            let entries = backlinks ?? []
            if entries.isEmpty {
                Text("No other sheet links here yet. Link with [[\(fileURL?.deletingPathExtension().lastPathComponent ?? "Sheet name")]].")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    Button {
                        onOpenBacklink(entry.url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.up.left").foregroundStyle(.secondary).frame(width: 16)
                            Text(entry.name).font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        let entries = TextStatistics.attachments(markdown: text)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Images & Links")
            if entries.isEmpty {
                Text("None yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: entry.kind == .image ? "photo" : (entry.kind == .wikiLink ? "doc.text" : "link"))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.label.isEmpty ? entry.target : entry.label).font(.callout).lineLimit(1)
                                Text(entry.target).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var tagHelp: String {
        var parts: [String] = []
        if onJumpToTag != nil { parts.append("Click a #tag to jump to it in the text.") }
        if onSelectTag != nil { parts.append(onJumpToTag == nil ? "Click a tag to filter the library by it." : "Click a keyword, or right-click a #tag, to filter the library by it.") }
        parts.append("Keywords are stored as `tags` in the front matter; `#tags` typed in the text count too.")
        return parts.joined(separator: " ")
    }

    private func open(_ entry: AttachmentEntry) {
        if entry.kind == .wikiLink {
            onOpenWikiLink?(entry.target)
            return
        }
        if let url = URL(string: entry.target), url.scheme != nil {
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            return
        }
        #if canImport(AppKit)
        let base = fileURL?.deletingLastPathComponent()
        let target = base.map { URL(fileURLWithPath: entry.target, relativeTo: $0).standardizedFileURL }
            ?? URL(fileURLWithPath: (entry.target as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([target])
        #endif
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Pieces

private struct StatTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(platform: .mmSecondaryBackground)))
    }
}

struct KeywordChip: View {
    let text: String
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let onTap {
                Button(action: onTap) { Text(text).font(.caption) }.buttonStyle(.plain)
            } else {
                Text(text).font(.caption)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

private struct GoalEditor: View {
    @State private var kind: WritingGoal.Kind
    @State private var mode: WritingGoal.Mode
    @State private var target: String
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    let hadGoal: Bool
    let onSave: (WritingGoal?) -> Void

    init(goal: WritingGoal?, onSave: @escaping (WritingGoal?) -> Void) {
        _kind = State(initialValue: goal?.kind ?? .words)
        _mode = State(initialValue: goal?.mode ?? .atLeast)
        _target = State(initialValue: String(goal?.target ?? 1000))
        _hasDeadline = State(initialValue: goal?.deadline != nil)
        _deadline = State(initialValue: goal?.deadline ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())!)
        hadGoal = goal != nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Writing Goal").font(.headline)
            HStack {
                Picker("", selection: $mode) {
                    ForEach(WritingGoal.Mode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                TextField("Target", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Picker("", selection: $kind) {
                    ForEach(WritingGoal.Kind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("Deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("", selection: $deadline, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack {
                if hadGoal {
                    Button("Remove Goal", role: .destructive) { onSave(nil) }
                }
                Spacer()
                Button("Save") {
                    let value = Int(target.filter(\.isNumber)) ?? 0
                    guard value > 0 else { return }
                    onSave(WritingGoal(kind: kind, mode: mode, target: value, deadline: hasDeadline ? deadline : nil))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Wraps its children onto as many rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
