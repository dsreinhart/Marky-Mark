//
//  PadTableEditor.swift
//  Markwright iPad
//
//  The table editor: a table from the formatted view as a grid of cells, with rows and columns
//  to add, remove and move and an alignment per column. Done writes the table back as Markdown.
//

import SwiftUI

/// A table open in the editor: where it starts in the formatted text (nil for a new one).
struct PadTableEdit: Identifiable {
    let id = UUID()
    let location: Int?
    let table: MarkdownTable
}

struct PadTableEditorView: View {
    let edit: PadTableEdit
    let onDone: (MarkdownTable) -> Void
    let onDelete: () -> Void
    @State private var table: MarkdownTable
    @State private var confirmDelete = false
    @FocusState private var focused: Cell?
    @Environment(\.dismiss) private var dismiss

    private struct Cell: Hashable {
        let row: Int    // -1 is the header row
        let column: Int
    }

    init(edit: PadTableEdit, onDone: @escaping (MarkdownTable) -> Void, onDelete: @escaping () -> Void) {
        self.edit = edit
        self.onDone = onDone
        self.onDelete = onDelete
        _table = State(initialValue: edit.table)
    }

    private let cellWidth: CGFloat = 170

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.frame(width: 30, height: 1)
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            columnMenu(column)
                        }
                    }
                    GridRow {
                        Text("").frame(width: 30)
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cellField(row: -1, column: column)
                        }
                    }
                    ForEach(0..<table.rows.count, id: \.self) { row in
                        GridRow {
                            rowMenu(row)
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                cellField(row: row, column: column)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button("Add Row", systemImage: "plus") {
                        table.insertRow(at: table.rows.count)
                        focused = Cell(row: table.rows.count - 1, column: 0)
                    }
                    Button("Add Column", systemImage: "plus") {
                        table.insertColumn(at: table.columnCount)
                        focused = Cell(row: -1, column: table.columnCount - 1)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.leading, 36)
                }
                .padding(20)
            }
            .defaultScrollAnchor(.topLeading)
            .navigationTitle(edit.location == nil ? "New Table" : "Edit Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edit.location == nil ? "Insert" : "Done") { onDone(table) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
                if edit.location != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete Table", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .confirmationDialog("Delete this table?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Table", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Undo in the document brings it back.")
            }
        }
        .presentationSizing(.page)
        .onAppear {
            focused = Cell(row: -1, column: 0)
        }
    }

    // MARK: - Pieces

    private func binding(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: {
                if row < 0 { return table.headers.indices.contains(column) ? table.headers[column] : "" }
                guard table.rows.indices.contains(row), table.rows[row].indices.contains(column) else { return "" }
                return table.rows[row][column]
            },
            set: { value in
                if row < 0 {
                    if table.headers.indices.contains(column) { table.headers[column] = value }
                } else if table.rows.indices.contains(row), table.rows[row].indices.contains(column) {
                    table.rows[row][column] = value
                }
            })
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .none {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private func cellField(row: Int, column: Int) -> some View {
        TextField(row < 0 ? "Header" : "", text: binding(row: row, column: column))
            .font(row < 0 ? .body.weight(.semibold) : .body)
            .multilineTextAlignment(textAlignment(column))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: cellWidth)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(row < 0 ? Color(.secondarySystemFill) : Color(.tertiarySystemFill)))
            .focused($focused, equals: Cell(row: row, column: column))
            .onSubmit { moveFocus(from: Cell(row: row, column: column)) }
            .submitLabel(.next)
    }

    /// Return moves along the row, then to the next row (adding one at the end).
    private func moveFocus(from cell: Cell) {
        if cell.column + 1 < table.columnCount {
            focused = Cell(row: cell.row, column: cell.column + 1)
        } else if cell.row + 1 < table.rows.count {
            focused = Cell(row: cell.row + 1, column: 0)
        } else {
            table.insertRow(at: table.rows.count)
            focused = Cell(row: table.rows.count - 1, column: 0)
        }
    }

    private func columnMenu(_ column: Int) -> some View {
        Menu {
            Picker("Alignment", selection: Binding(
                get: { table.alignments.indices.contains(column) ? table.alignments[column] : .none },
                set: { if table.alignments.indices.contains(column) { table.alignments[column] = $0 } })) {
                ForEach(MarkdownTable.Alignment.allCases) { alignment in
                    Text(alignment.label).tag(alignment)
                }
            }
            Divider()
            Button("Insert Column Before", systemImage: "arrow.left.to.line") { table.insertColumn(at: column) }
            Button("Insert Column After", systemImage: "arrow.right.to.line") { table.insertColumn(at: column + 1) }
            Button("Move Left", systemImage: "arrow.left") { table.moveColumn(from: column, by: -1) }
                .disabled(column == 0)
            Button("Move Right", systemImage: "arrow.right") { table.moveColumn(from: column, by: 1) }
                .disabled(column == table.columnCount - 1)
            Divider()
            Button("Delete Column", systemImage: "trash", role: .destructive) { table.removeColumn(at: column) }
                .disabled(table.columnCount == 1)
        } label: {
            Label("Column \(column + 1)", systemImage: "chevron.down")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: cellWidth)
        }
    }

    private func rowMenu(_ row: Int) -> some View {
        Menu {
            Button("Insert Row Above", systemImage: "arrow.up.to.line") { table.insertRow(at: row) }
            Button("Insert Row Below", systemImage: "arrow.down.to.line") { table.insertRow(at: row + 1) }
            Button("Move Up", systemImage: "arrow.up") { table.moveRow(from: row, by: -1) }
                .disabled(row == 0)
            Button("Move Down", systemImage: "arrow.down") { table.moveRow(from: row, by: 1) }
                .disabled(row == table.rows.count - 1)
            Divider()
            Button("Delete Row", systemImage: "trash", role: .destructive) { table.removeRow(at: row) }
        } label: {
            Text("\(row + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Row \(row + 1)")
    }
}
