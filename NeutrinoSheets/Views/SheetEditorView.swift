import SwiftUI

// MARK: - SheetEditorView

/// One open workbook: the tab bar, the formula bar, and the grid.
///
/// Epic 6 renders it, Epic 7 loads and saves it, and Epic 8's first slice — tap to select, tap
/// again to edit a literal — is what makes it more than a viewer. Everything the grid itself does
/// lives in ``SheetGridView``; this view is the SwiftUI shell around it.
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
    @State private var showRename = false
    @State private var formulaWarning = false
    @FocusState private var isEditorFocused: Bool

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
                    onActivate: beginEditing
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
    /// without somewhere to show `raw` there is no way to see that a cell is a formula at all.
    private var formulaBar: some View {
        HStack(spacing: 8) {
            Text(model.selection?.id ?? "—")
                .font(.system(.footnote, design: .monospaced))
                .frame(minWidth: 52)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))

            Divider().frame(height: 22)

            if let editingText {
                TextField("Value", text: Binding(
                    get: { editingText },
                    set: { self.editingText = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isEditorFocused)
                .submitLabel(.done)
                .onSubmit(commitEditing)

                Button("Done", action: commitEditing)
                    .font(.footnote.weight(.semibold))
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
                        if let selection = model.selection { beginEditing(selection) }
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
                        model.activeSheetIndex = index
                        model.selection = CellAddress(column: 1, row: 1)
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

    private var statusBar: some View {
        HStack(spacing: 8) {
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
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(.secondarySystemBackground))
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
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
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

    // MARK: - Editing

    private func beginEditing(_ address: CellAddress) {
        guard model.isEditable else { return }
        model.selection = address
        editingText = model.activeSheet?.cells[address.id]?.editableText ?? ""
        isEditorFocused = true
    }

    private func commitEditing() {
        guard let text = editingText, let selection = model.selection else { return }
        // Refused rather than mangled: with no evaluator, storing a formula would write a `value`
        // that is simply the formula's text, and the web app would then show that text where a
        // number belongs. See `SheetEditorModel.commitEdit`.
        guard !SheetEditorModel.isFormula(text) else {
            formulaWarning = true
            return
        }
        model.commitEdit(text, at: selection)
        editingText = nil
        isEditorFocused = false
        model.saveIfNeeded()
    }

    private func cancelEditing() {
        editingText = nil
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
