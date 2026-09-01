import SwiftUI

// MARK: - SheetEditorView

/// One open workbook: the tab bar, the formula bar, and the grid.
///
/// Epic 6 renders it, Epic 7 loads and saves it, and Epic 8 turns it into an editor — tap to
/// select, double-tap to type, drag to select a range, fill, cut and paste, undo. Everything the
/// grid itself does lives in ``SheetGridView``; this view is the SwiftUI shell around it.
struct SheetEditorView: View {

    // MARK: - Input

    let item: SheetItem

    // MARK: - Environment

    @EnvironmentObject private var contentService: SheetContentService
    @EnvironmentObject private var driveService: SheetsDriveService
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @StateObject private var model: SheetEditorModel

    /// The text being typed into the selected cell, or nil when not editing.
    @State private var editingText: String?
    /// The cell the entry belongs to, which is *not* always the selected one: a tap elsewhere moves
    /// the selection while the keyboard is still up, and committing to wherever the selection had
    /// got to would write the value into the wrong cell.
    @State private var editingAddress: CellAddress?
    @State private var isEditorFocused = false
    @State private var showRename = false
    @State private var formulaWarning = false
    /// Epic 9 — the full formatting sheet, opened from the format bar or the actions menu.
    @State private var showFormatSheet = false
    /// Epic 10 — find & replace, the per-column filter list, and the two tab dialogs. Each holds
    /// what it is *about* rather than a bare flag, so the sheet cannot open pointing at nothing.
    @State private var showFindReplace = false
    @State private var filterColumn: GridIndex?
    @State private var renamingTab: GridIndex?
    @State private var colouringTab: GridIndex?

    // MARK: - Init

    init(item: SheetItem) {
        self.item = item
        // The model needs services the environment cannot supply this early, so it is built with
        // placeholders and re-pointed in `.task`. Constructing it here rather than lazily is what
        // keeps it alive across the view's re-evaluations.
        _model = StateObject(wrappedValue: SheetEditorModel(
            item: item, contentService: SheetContentService(), driveService: nil
        ))
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await load() }
            // A `.task` rather than a loose `Task {}`: SwiftUI cancels it when the view goes away,
            // and a detached timer would go on saving a workbook nobody has open.
            .task { await autosaveLoop() }
            .onDisappear { flush() }
            .onChange(of: scenePhase) { phase in
                // Epic 7 — "Save on background/terminate". `.inactive` fires first and is the last
                // moment the app is reliably given time to finish a request.
                if phase != .active { flush() }
            }
            .onChange(of: model.selection) { selectionMoved(to: $0) }
            .sheet(isPresented: $showRename) {
                RenameSheet(item: item)
            }
            .sheet(isPresented: $showFormatSheet) {
                FormatSheet(style: model.selectionStyle,
                            isMerged: model.isSelectionMerged,
                            selectionAddress: model.selection?.address ?? "",
                            perform: perform)
            }
            .sheet(isPresented: $showFindReplace) {
                FindReplaceView(model: model)
            }
            .sheet(item: $filterColumn) { target in
                ColumnFilterView(column: target.id,
                                 values: model.filterValues(inColumn: target.id),
                                 current: model.columnFilters.allowed[target.id]) { values in
                    model.setFilter(values, forColumn: target.id)
                }
            }
            // Both index into the tab list, which an undo or a delete can shorten while the sheet
            // is up, so both check the index still exists rather than trapping on it.
            .sheet(item: $renamingTab) { target in
                if model.sheetNames.indices.contains(target.id) {
                    SheetTabRenameView(currentName: model.sheetNames[target.id]) { name in
                        model.renameSheet(at: target.id, to: name)
                        model.saveIfNeeded()
                    }
                }
            }
            .sheet(item: $colouringTab) { target in
                if let sheets = model.file?.sheets, sheets.indices.contains(target.id) {
                    SheetTabColorView(current: sheets[target.id].color) { color in
                        model.setSheetColor(color, at: target.id)
                        model.saveIfNeeded()
                    }
                }
            }
            .alert("Formulas aren\u{2019}t supported yet", isPresented: $formulaWarning) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("This version can edit values but not formulas. A formula typed here would be "
                     + "saved with the wrong result, so it is refused. Edit formulas on the web for now.")
            }
            .alert(item: $model.conflict) { conflict in
                conflictAlert(conflict)
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.file == nil {
            ProgressView("Opening\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = model.loadError {
            errorState(loadError)
        } else {
            VStack(spacing: 0) {
                if settings.showFormulaBar {
                    formulaBar
                    Divider()
                }

                SheetGridView(
                    sheet: model.activeSheet,
                    selection: $model.selection,
                    metrics: settings.gridMetrics,
                    showGridLines: settings.showGridLines,
                    frozen: model.frozen,
                    hiddenRows: model.filteredRows,
                    filteredColumns: Set(model.columnFilters.columns),
                    allowsStructure: FeatureFlags.structure,
                    isEditable: model.isEditable,
                    isEditingCell: editingText != nil,
                    canPaste: model.canPaste,
                    onActivate: beginEditing,
                    onFill: { model.fill(to: $0) },
                    onCommand: perform,
                    onStructure: perform
                )

                // Epic 9 — the format bar sits under the grid rather than over it: it is used with
                // a thumb while the eye is on the cells, and a bar at the top would put the
                // controls at the far end of the reach from where the selection is.
                if showsFormatBar {
                    Divider()
                    FormatBar(style: model.selectionStyle,
                              isMerged: model.isSelectionMerged,
                              perform: perform,
                              onMore: { showFormatSheet = true })
                }

                // Epic 10 gives the bar an "add" button, so it earns its place on a one-tab
                // workbook too — a second tab has to be reachable from somewhere.
                if model.sheetNames.count > 1 || model.isEditable {
                    Divider()
                    tabBar
                }

                statusBar
            }
        }
    }

    /// Whether the format bar is shown. Hidden on a read-only share for the same reason the fill
    /// handle is: a viewer should get a viewer, not an editor whose every control does nothing.
    private var showsFormatBar: Bool {
        FeatureFlags.formatting && settings.showFormatBar && model.isEditable
    }

    // MARK: - Formula bar

    /// Epic 8 — "Formula bar with cell reference box".
    ///
    /// The reference box on the left is not decoration: a cell shows its *evaluated* value, so
    /// without somewhere to show `raw` there is no way to see that a cell is a formula at all. It
    /// doubles as the range readout — `A1:C10` while a block is selected.
    private var formulaBar: some View {
        HStack(spacing: 8) {
            Text(model.selection?.address ?? "—")
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 52)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Selection \(model.selection?.address ?? "none")")

            Divider().frame(height: 22)

            if editingText != nil {
                CellEntryField(
                    text: Binding(get: { editingText ?? "" }, set: { editingText = $0 }),
                    isFocused: $isEditorFocused,
                    onCommit: finishEditing
                )
                .frame(maxWidth: .infinity)

                Button {
                    cancelEditing()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancel edit")
            } else {
                Text(model.selectedCell?.editableText ?? "")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let active = model.selection?.active { beginEditing(active) }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    // MARK: - Tab bar

    /// Epic 6 — "Tab bar for multi-sheet workbooks"; Epic 10 — "Add / rename / colour / reorder /
    /// duplicate / delete sheet tabs".
    ///
    /// Every tab operation lives in a long-press menu on the tab itself rather than in the actions
    /// menu at the top. A tab command is *about* one tab, and on a phone the shortest way to say
    /// which one is to press it — the alternative is a menu that first asks you to pick a tab from
    /// a list of the tabs already on screen.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.sheetNames.enumerated()), id: \.offset) { index, name in
                    Button {
                        cancelEditing()
                        model.selectSheet(at: index)
                    } label: {
                        HStack(spacing: 6) {
                            if let color = tabColor(at: index) {
                                Circle().fill(color).frame(width: 7, height: 7)
                            }
                            Text(name)
                                .font(.footnote)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            index == model.activeSheetIndex
                                ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .foregroundStyle(index == model.activeSheetIndex ? Color.accentColor : Color.secondary)
                    }
                    .contextMenu { tabMenu(at: index) }
                }

                if model.isEditable {
                    Button {
                        cancelEditing()
                        model.addSheet()
                        model.saveIfNeeded()
                    } label: {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .accessibilityLabel("Add sheet")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func tabMenu(at index: Int) -> some View {
        if model.isEditable {
            Section {
                Button {
                    renamingTab = GridIndex(id: index)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    colouringTab = GridIndex(id: index)
                } label: {
                    Label("Colour\u{2026}", systemImage: "paintpalette")
                }
                Button {
                    model.duplicateSheet(at: index)
                    model.saveIfNeeded()
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
            }

            Section {
                Button {
                    model.moveSheet(at: index, by: -1)
                    model.saveIfNeeded()
                } label: {
                    Label("Move Left", systemImage: "arrow.left")
                }
                .disabled(index == 0)

                Button {
                    model.moveSheet(at: index, by: 1)
                    model.saveIfNeeded()
                } label: {
                    Label("Move Right", systemImage: "arrow.right")
                }
                .disabled(index == model.sheetNames.count - 1)
            }

            Section {
                Button(role: .destructive) {
                    model.deleteSheet(at: index)
                    model.saveIfNeeded()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!model.canDeleteSheet)
            }
        }
    }

    private func tabColor(at index: Int) -> Color? {
        guard let file = model.file, file.sheets.indices.contains(index),
              let raw = file.sheets[index].color,
              let uiColor = GridStyleResolver.color(raw) else { return nil }
        return Color(uiColor)
    }

    // MARK: - Status bar

    /// Epic 8 — "a live sum/count/average status bar".
    ///
    /// The summary takes the bar whenever a block is selected, because that is the moment it is
    /// being asked for. Save state is what the bar says the rest of the time, and it moves to the
    /// right so it never disappears entirely.
    private var statusBar: some View {
        // Computed once: `summary` walks the selection, and reading it twice in one layout pass
        // would walk it twice.
        let summary = model.summary
        let notice = model.notice

        return HStack(spacing: 8) {
            if let summary {
                Text(summary.statusText)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(summary.statusText)
            } else if let notice {
                Image(systemName: "info.circle")
                Text(notice).lineLimit(1)
            } else {
                saveStatus
            }

            Spacer(minLength: 8)

            if summary != nil || notice != nil {
                saveStatus
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private var saveStatus: some View {
        HStack(spacing: 5) {
            if model.isSaving {
                ProgressView().controlSize(.mini)
                Text("Saving\u{2026}")
            } else if model.hasUnsavedChanges {
                Image(systemName: "circle.fill").font(.system(size: 6))
                Text("Unsaved changes")
            } else if let saveError = model.saveError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(saveError).lineLimit(1)
            } else if !model.isEditable {
                Image(systemName: "eye")
                Text(readOnlyReason)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("Saved")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var readOnlyReason: String {
        guard FeatureFlags.cellEditing else { return "Read only" }
        guard let role = model.info?.yourRole else { return "Read only" }
        return "Read only \u{00B7} shared as \(role.displayName.lowercased())"
    }

    // MARK: - Error state

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Epic 8 — "Undo / redo". In the bar rather than buried in the menu: undo is the command
        // that has to be reachable without thinking, especially on a touchscreen where a fill can
        // rewrite fifty cells from one gesture.
        if model.isEditable {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { perform(.undo) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .accessibilityLabel(model.undoName.map { "Undo \($0)" } ?? "Undo")

                Button { perform(.redo) } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .accessibilityLabel(model.redoName.map { "Redo \($0)" } ?? "Redo")
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                if model.selection != nil {
                    Section {
                        Button {
                            perform(.cut)
                        } label: {
                            Label("Cut", systemImage: "scissors")
                        }
                        .disabled(!model.isEditable)

                        Button {
                            perform(.copy)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        Button {
                            perform(.paste)
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .disabled(!model.canPaste)

                        Button(role: .destructive) {
                            perform(.clear)
                        } label: {
                            Label("Clear", systemImage: "eraser")
                        }
                        .disabled(!model.isEditable)
                    }

                    // Epic 9. Here as well as on the format bar, because the bar is a setting the
                    // user can switch off and formatting must not go with it.
                    if FeatureFlags.formatting && model.isEditable {
                        Section {
                            Button {
                                showFormatSheet = true
                            } label: {
                                Label("Format\u{2026}", systemImage: "textformat")
                            }
                        }
                    }

                    // Epic 10. The header menu is the quicker route to all of this, but it is only
                    // reachable by pressing a header — and a user who has not discovered that needs
                    // somewhere to find "insert a row" that they already know about.
                    if FeatureFlags.structure && model.isEditable {
                        structureSection
                    }
                }

                if FeatureFlags.structure {
                    Section {
                        Button {
                            showFindReplace = true
                        } label: {
                            Label("Find & Replace\u{2026}", systemImage: "magnifyingglass")
                        }

                        if !model.columnFilters.isEmpty {
                            Button {
                                model.clearAllFilters()
                            } label: {
                                Label("Clear All Filters", systemImage: "line.3.horizontal.decrease")
                            }
                        }
                    }
                }

                Section {
                    Button {
                        model.queueSave()
                    } label: {
                        Label("Save Now", systemImage: "arrow.up.circle")
                    }
                    .disabled(!model.isEditable)

                    if !item.isShared {
                        Button {
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Actions")
        }
    }

    /// Epic 10 — the structural commands, mirroring the header menu.
    @ViewBuilder
    private var structureSection: some View {
        Section {
            Menu {
                Button { perform(.insertRows(before: true)) } label: {
                    Label("Rows Above", systemImage: "arrow.up")
                }
                Button { perform(.insertRows(before: false)) } label: {
                    Label("Rows Below", systemImage: "arrow.down")
                }
                Button { perform(.insertColumns(before: true)) } label: {
                    Label("Columns Left", systemImage: "arrow.left")
                }
                Button { perform(.insertColumns(before: false)) } label: {
                    Label("Columns Right", systemImage: "arrow.right")
                }
            } label: {
                Label("Insert", systemImage: "plus.rectangle")
            }

            Menu {
                Button(role: .destructive) { perform(.deleteRows) } label: {
                    Label("Rows", systemImage: "trash")
                }
                Button(role: .destructive) { perform(.deleteColumns) } label: {
                    Label("Columns", systemImage: "trash")
                }
            } label: {
                Label("Delete", systemImage: "minus.rectangle")
            }

            Menu {
                Button { perform(.hideRows) } label: {
                    Label("Hide Rows", systemImage: "eye.slash")
                }
                Button { perform(.hideColumns) } label: {
                    Label("Hide Columns", systemImage: "eye.slash")
                }
                if model.hasHiddenRowsOrColumns {
                    Button { model.showEverything(); model.saveIfNeeded() } label: {
                        Label("Show All", systemImage: "eye")
                    }
                }
                if model.frozen.isEmpty {
                    Button { perform(.freezeToSelection) } label: {
                        Label("Freeze Up To Selection", systemImage: "lock")
                    }
                } else {
                    Button { perform(.unfreeze) } label: {
                        Label("Unfreeze Panes", systemImage: "lock.open")
                    }
                }
            } label: {
                Label("View", systemImage: "rectangle.split.3x1")
            }
        }
    }

    // MARK: - Conflict

    private func conflictAlert(_ conflict: SheetEditorModel.ConflictState) -> Alert {
        // Epic 7 — "409 conflict surfaced to the user, never silently overwritten". Both outcomes
        // lose something, so both are named plainly and neither is the default.
        Alert(
            title: Text("Changed Somewhere Else"),
            message: Text("This spreadsheet was edited on another device since you opened it. "
                          + "Reloading discards your changes here; keeping yours overwrites theirs."),
            primaryButton: .destructive(Text("Keep Mine")) {
                model.keepLocalCopyAfterConflict()
            },
            secondaryButton: .default(Text("Reload")) {
                Task { await model.reloadAfterConflict() }
            }
        )
    }

    // MARK: - Commands

    /// Everything the grid asks for and the menu offers, in one place so a keyboard shortcut, an
    /// edit-menu item and a toolbar button cannot drift apart.
    private func perform(_ command: GridCommand) {
        // A command arriving mid-entry has to see the typed value, not the one underneath it.
        commitPendingEntry()
        switch command {
        case .cut:   model.copySelection(cut: true)
        case .copy:  model.copySelection()
        case .paste: model.paste()
        case .clear: model.clearSelection()
        case .undo:  model.undo()
        case .redo:  model.redo()
        }
        model.saveIfNeeded()
    }

    /// Epic 9 — the formatting counterpart of ``perform(_:)``.
    ///
    /// Kept separate from `GridCommand` because the two travel different routes — one comes from
    /// the grid's own gestures and key commands, the other from SwiftUI controls — but both commit
    /// a pending entry first, for the same reason: a style applied while a value is half-typed must
    /// land on the cell the user is looking at, not on the one underneath the entry.
    private func perform(_ command: FormatCommand) {
        commitPendingEntry()
        switch command {
        case .style(let patch, let name): model.applyStyle(patch, name: name)
        case .toggleMerge:                model.toggleMerge()
        case .clearFormatting:            model.clearFormatting()
        case .tableStyle(let style):      model.applyTableStyle(style)
        }
        model.saveIfNeeded()
    }

    /// Epic 10 — the structural counterpart, from the header menu and the actions menu.
    ///
    /// `filter` and `clearFilter` are the two that are not edits: a filter changes how the workbook
    /// is looked at, so neither queues a save, and `filter` only opens a sheet.
    private func perform(_ command: StructureCommand) {
        commitPendingEntry()
        switch command {
        case .insertRows(let before):     model.insertRows(before: before)
        case .insertColumns(let before):  model.insertColumns(before: before)
        case .deleteRows:                 model.deleteRows()
        case .deleteColumns:              model.deleteColumns()
        case .hideRows:                   model.hideRows()
        case .hideColumns:                model.hideColumns()
        case .show:                       model.showSelection()
        case .sort(let column, let ascending):
            model.sort(by: column, ascending: ascending)
        case .resizeColumns(let columns, let width):
            model.resize(columns: columns, to: width,
                         name: columns.count > 1 ? "Resize Columns" : "Resize Column")
        case .resizeRows(let rows, let height):
            model.resize(rows: rows, to: height,
                         name: rows.count > 1 ? "Resize Rows" : "Resize Row")
        case .freezeToSelection:          model.freezeToSelection()
        case .unfreeze:                   model.unfreeze()
        case .filter(let column):
            filterColumn = GridIndex(id: column)
            return
        case .clearFilter(let column):
            model.setFilter(nil, forColumn: column)
            return
        }
        model.saveIfNeeded()
    }

    // MARK: - Editing

    private func beginEditing(_ address: CellAddress) {
        guard model.isEditable else { return }
        model.selection = SheetSelection(address)
        editingText = model.activeSheet?.cells[address.id]?.editableText ?? ""
        editingAddress = address
        isEditorFocused = true
    }

    /// Commits what was typed and moves on, if the commit asked to.
    private func finishEditing(_ commit: CellEntryCommit) {
        guard let text = editingText, let address = editingAddress else { return }

        if case .cancelled = commit {
            cancelEditing()
            return
        }

        // Refused rather than mangled: with no evaluator, storing a formula would write a `value`
        // that is simply the formula's text, and the web app would then show that text where a
        // number belongs. See `SheetEditorModel.commitEdit`.
        guard !SheetEditorModel.isFormula(text) else {
            formulaWarning = true
            return
        }

        model.commitEdit(text, at: address)
        editingText = nil
        editingAddress = nil
        isEditorFocused = false

        if case .move(let columns, let rows) = commit {
            model.selection = SheetSelection(address.offset(columns: columns, rows: rows))
        }
        model.saveIfNeeded()
    }

    /// Commits a half-typed entry without moving — used before any command that reads the workbook,
    /// and when the selection leaves the cell being typed into.
    private func commitPendingEntry() {
        guard editingText != nil else { return }
        finishEditing(.done)
    }

    /// Ends an entry when the selection moves off the cell it belongs to.
    ///
    /// A tap on another cell while the keyboard is up is a commit, the way it is in every
    /// spreadsheet. Without this the entry stays open over a cell it no longer describes.
    private func selectionMoved(to selection: SheetSelection?) {
        guard let editingAddress, editingText != nil else { return }
        guard selection?.active != editingAddress else { return }
        commitPendingEntry()
    }

    private func cancelEditing() {
        editingText = nil
        editingAddress = nil
        isEditorFocused = false
    }

    // MARK: - Lifecycle

    private func load() async {
        model.attach(contentService: contentService, driveService: driveService)
        await model.load()
    }

    /// Epic 8 — "Autosave on an interval from Settings".
    ///
    /// A tick only ever *queues* a save; the chain in ``SheetEditorModel`` decides when it runs, so
    /// a slow upload cannot cause two to overlap however often this fires.
    private func autosaveLoop() async {
        while !Task.isCancelled {
            let interval = UInt64(settings.autoSaveInterval * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                return  // Cancelled — the editor is going away.
            }
            model.saveIfNeeded()
        }
    }

    private func flush() {
        Task { await model.flush() }
    }
}
