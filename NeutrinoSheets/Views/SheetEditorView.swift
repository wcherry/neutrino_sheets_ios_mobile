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
                    isEditable: model.isEditable,
                    isEditingCell: editingText != nil,
                    canPaste: model.canPaste,
                    onActivate: beginEditing,
                    onFill: { model.fill(to: $0) },
                    onCommand: perform
                )

                if model.sheetNames.count > 1 {
                    Divider()
                    tabBar
                }

                statusBar
            }
        }
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

    /// Epic 6 — "Tab bar for multi-sheet workbooks". Read-only in Phase 1; adding, renaming and
    /// reordering tabs is Epic 10.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.sheetNames.enumerated()), id: \.offset) { index, name in
                    Button {
                        cancelEditing()
                        model.activeSheetIndex = index
                        model.selection = SheetSelection(CellAddress(column: 1, row: 1))
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
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(Color(.secondarySystemBackground))
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
