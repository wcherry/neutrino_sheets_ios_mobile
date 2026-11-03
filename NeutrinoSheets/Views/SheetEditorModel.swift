import Foundation
import Sodium
import os.log

// MARK: - SheetEditorModel

/// The state of one open workbook: what was loaded, what has changed, and what is being written.
///
/// Kept out of the view because three of its responsibilities are genuinely stateful and easy to
/// get wrong in a `View`'s `@State`:
///
/// - **The save chain.** Never two autosave PUTs in flight at once. The web app hit real body
///   truncation doing that (see `usePersistence`'s `saveChainRef`), and the same shape of bug on a
///   phone would silently drop an edit.
/// - **Conflict.** A 409 is a decision for the user, not something to retry into.
/// - **Editing.** Every mutation goes through one funnel (``apply(_:name:selectionAfter:)``) so
///   that undo, the dirty flag and the selection cannot fall out of step with the cells — which is
///   exactly what happens when each command mutates the workbook its own way.
@MainActor
final class SheetEditorModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var file: SheetFile?
    @Published private(set) var info: SheetFileInfo?
    @Published var activeSheetIndex: Int = 0
    /// The selected block and its active cell. See ``SheetSelection``.
    @Published var selection: SheetSelection?

    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasUnsavedChanges = false
    @Published var loadError: String?
    /// Set when the workbook on screen is this device's offline copy, kept on this date, because
    /// the server could not be reached. It is read-only until reloaded from the server.
    @Published private(set) var offlineCopyDate: Date?
    @Published var saveError: String?
    /// A short, self-clearing message for something worth saying but not worth interrupting for —
    /// "3 cells pasted", or the note that pasted formulas recalculate on the web.
    @Published private(set) var notice: String?
    /// Set when the server refused a save because the workbook moved on elsewhere. Surfaced to the
    /// user, never resolved silently — overwriting is not this app's decision to make.
    @Published var conflict: ConflictState?

    /// Bumped on every recorded edit, purely so SwiftUI re-reads ``canUndo`` / ``canRedo``. The
    /// history itself is a value type inside a non-published property; without this the toolbar
    /// buttons would keep whatever enabled state they were first drawn with.
    @Published private(set) var historyToken = 0

    struct ConflictState: Identifiable {
        let id = UUID()
        /// The version the server holds now, when it could be recovered from the error body.
        let serverVersion: Int?
    }

    // MARK: - Dependencies

    private let item: SheetItem
    private var contentService: SheetContentService
    /// Keeps the Drive preview showing page one. Made on load, once the file is known.
    private var previewer: SheetPreviewer?
    private weak var driveService: SheetsDriveService?
    private let pasteboard: PasteboardWriting

    // MARK: - Session state

    /// The workbook's DEK, held for the session so a save needs neither a re-fetch nor a re-unseal.
    private var dek: Bytes?
    /// The version the loaded content was read at, sent as `expectedContentVersion` on the next save
    /// and advanced by each successful one.
    private var contentVersion: Int?
    /// True until the plaintext the server seeded at create time has been replaced by ciphertext.
    private var needsInitialEncryption = false
    /// The `.xlsx` this session opened, handed back to every save so the parts neither this app nor
    /// the web models — a pivot table, an image, a chart Excel wrote — survive an edit made here.
    private var sourcePackage: Data?

    /// Epic 8 — "Undo / redo".
    private var history = EditHistory()

    /// Where the last cut came from, so the paste that follows can clear it.
    ///
    /// The source is *not* cleared at cut time. A cut with no paste has to leave the workbook
    /// exactly as it was — on a phone, where a cut can be followed by a phone call rather than a
    /// paste, clearing early is a way to lose data.
    private var cutSource: (sheetIndex: Int, range: CellRange)?

    /// The chain every save links onto, so no two writes overlap. Awaiting the previous task before
    /// starting the next is the whole mechanism.
    private var saveChain: Task<Void, Never>?

    /// True between a save being queued and it starting to run.
    ///
    /// Used to coalesce: a save that has not begun yet will serialise whatever the workbook holds
    /// at the moment it does, so queueing a second one behind it would upload identical bytes
    /// twice. Without this, a single edit produces two PUTs — the timer's and the flush's.
    private var isSaveQueued = false

    /// Clears ``notice`` after a beat, cancelled and restarted by each new one.
    private var noticeTask: Task<Void, Never>?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoSheets",
                                category: "SheetEditorModel")

    // MARK: - Init

    init(item: SheetItem, contentService: SheetContentService, driveService: SheetsDriveService?,
         pasteboard: PasteboardWriting = SystemPasteboard()) {
        self.item = item
        self.contentService = contentService
        self.driveService = driveService
        self.pasteboard = pasteboard
    }

    /// Re-points the model at the environment's services.
    ///
    /// The view constructs this model in its `init`, where `@EnvironmentObject` is not yet readable,
    /// so it starts with a placeholder content service and no drive service. This is called from
    /// `.task`, before ``load()``, and is idempotent.
    func attach(contentService: SheetContentService, driveService: SheetsDriveService?) {
        self.contentService = contentService
        self.driveService = driveService
    }

    // MARK: - Derived

    var title: String { info?.name ?? item.name }

    /// Whether this account may write to the workbook. A spreadsheet shared read-only opens in a
    /// viewer, and every editing affordance is hidden rather than disabled-on-tap.
    var isEditable: Bool {
        FeatureFlags.cellEditing && (info?.isEditable ?? false) && offlineCopyDate == nil
    }

    var sheetNames: [String] {
        (file?.sheets ?? []).enumerated().map { index, sheet in
            sheet.name ?? "Sheet \(index + 1)"
        }
    }

    var activeSheet: SheetData? {
        guard let file, file.sheets.indices.contains(activeSheetIndex) else { return nil }
        return file.sheets[activeSheetIndex]
    }

    /// The cell the selection's active corner names, if it holds anything.
    var selectedCell: SavedCell? {
        guard let selection else { return nil }
        return activeSheet?.cells[selection.active.id]
    }

    /// Epic 8 — the live sum / count / average under a range selection.
    ///
    /// Nil for a single cell: a status bar reading "Sum 42, Count 1" over one cell is repeating
    /// what the cell already says.
    var summary: RangeSummary? {
        guard let selection, !selection.isSingleCell, let sheet = activeSheet else { return nil }
        let summary = RangeSummary(range: selection.range, cells: sheet.cells)
        return summary.isEmpty ? nil : summary
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var undoName: String? { history.undoName }
    var redoName: String? { history.redoName }

    /// Whether the clipboard holds anything. Asks without reading, so checking does not put the
    /// system's paste permission banner in front of the user.
    var canPaste: Bool { isEditable && pasteboard.hasContent }

    // MARK: - Loading

    func load() async {
        guard !isLoading, file == nil else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let loaded = try await contentService.loadWorkbook(for: item.id)
            file = loaded.file
            info = loaded.info
            dek = loaded.dek
            contentVersion = loaded.info.contentVersion
            needsInitialEncryption = loaded.needsInitialEncryption
            sourcePackage = loaded.sourcePackage
            offlineCopyDate = loaded.offlineCopyDate
            activeSheetIndex = 0
            selection = SheetSelection(CellAddress(column: 1, row: 1))
            history.clear()
            cutSource = nil

            // An offline copy is read-only and its preview is the server's business.
            if offlineCopyDate == nil {
                let previewer = SheetPreviewer(fileID: item.id, contentService: contentService)
                self.previewer = previewer
                previewer.loaded(loaded.file, hasPreview: loaded.info.hasPreview, canEdit: isEditable)
            }

            // A brand-new spreadsheet is still holding the server's *plaintext* seed. Encrypting it
            // is the first thing to do, before the user can type anything into it — but through the
            // save chain, so it can never race a save triggered moments later by a fast edit.
            if needsInitialEncryption {
                logger.debug("load: id=\(self.item.id, privacy: .public) needs initial encryption")
                queueSave()
            }
        } catch {
            logger.error("load failed: \(error, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // MARK: - Editing

    /// Commits a literal value typed into a cell.
    ///
    /// Phase 1 *typing* is literals only. `raw` and `value` are written to the same text, which is
    /// correct for a literal and deliberately wrong for a formula — there is no evaluator yet
    /// (Epic 15), so a formula typed here would be stored with a display value it does not produce.
    /// ``isFormula(_:)`` is what the editor uses to refuse that. Paste and fill take a different
    /// route: see ``SheetClipboard/changes(at:into:existing:)``.
    ///
    /// Cells that end up empty are removed rather than stored blank, matching what the web app
    /// writes: an empty cell is an absent key, not a key holding "".
    func commitEdit(_ text: String, at address: CellAddress) {
        guard let sheet = activeSheet else { return }
        var cell = sheet.cells[address.id] ?? SavedCell(id: address.id)
        cell.raw = text.isEmpty ? nil : text
        cell.value = text.isEmpty ? nil : text

        var changes = CellChanges()
        changes.updateValue(cell.isEmpty ? nil : cell, forKey: address.id)
        // No selection override: where the cursor goes after an entry is the view's business —
        // Return steps down, an arrow steps sideways, and a tap elsewhere has already moved it.
        // Forcing it back to `address` here would yank the selection off the cell the user just
        // tapped.
        apply(changes, name: "Typing")
    }

    /// Empties every selected cell, keeping its formatting — the Delete key, and the "Clear"
    /// command. Formatting is left because clearing values and clearing formatting are two
    /// different intentions, and Epic 9 is where the second one lives.
    func clearSelection() {
        guard let sheet = activeSheet, let selection else { return }
        var changes = CellChanges()
        for address in selection.range.addresses {
            guard var cell = sheet.cells[address.id] else { continue }
            // Nothing to clear, and recording it would put an edit that changed nothing into the
            // history.
            guard !(cell.raw ?? "").isEmpty || !(cell.value ?? "").isEmpty else { continue }
            cell.raw = nil
            cell.value = nil
            changes.updateValue(cell.isEmpty ? nil : cell, forKey: address.id)
        }
        apply(changes, name: "Clear")
    }

    /// Whether text is a formula, which Phase 1 cannot evaluate.
    static func isFormula(_ text: String) -> Bool {
        FormulaReferences.isFormula(text)
    }

    // MARK: - Formatting

    /// Epic 9 — the style the format controls show as current.
    ///
    /// Read from the active cell rather than reconciled across the whole selection: a range whose
    /// cells disagree has no single answer, and the web app's toolbar reads its anchor for exactly
    /// that reason. The active cell is the one the formula bar is editing, so it is the one the
    /// user is looking at.
    var selectionStyle: CellStyle? { selectedCell?.cellStyle }

    /// True when the selection's top-left cell is a merge anchor, so the control reads "Unmerge".
    var isSelectionMerged: Bool {
        guard let selection, let sheet = activeSheet else { return false }
        return MergeEngine.mergeOrigin(at: selection.range.start, cells: sheet.cells) != nil
    }

    /// The table regions on the active tab.
    var tableRegions: [TableRegion] { activeSheet?.tables ?? [] }

    /// Applies one style patch to every cell in the selection.
    ///
    /// A patch can land on a cell that holds nothing, and that is deliberate: formatting an empty
    /// range is how a user prepares a table before typing into it, and the web app stores those
    /// cells too. What is *not* stored is a cell the patch leaves with no style and no content —
    /// clearing formatting from an empty cell removes the key rather than leaving `{"id":"B2"}`
    /// behind.
    func applyStyle(_ patch: CellStylePatch, name: String) {
        guard isEditable, let sheet = activeSheet, let selection, !patch.isEmpty else { return }
        var changes = CellChanges()
        for address in selection.range.addresses {
            var cell = sheet.cells[address.id] ?? SavedCell(id: address.id)
            cell.cellStyle = patch.applied(to: cell.cellStyle)
            changes.updateValue(cell.isEmpty ? nil : cell, forKey: address.id)
        }
        apply(changes, name: name)
    }

    /// Applies a different patch per cell — what a table style produces. One undo entry covers the
    /// whole block, because applying a table style is one act.
    func applyStyles(_ patches: [String: CellStylePatch], name: String,
                     tables: [TableRegion]? = nil) {
        guard isEditable, let sheet = activeSheet else { return }
        var changes = CellChanges()
        for (id, patch) in patches {
            var cell = sheet.cells[id] ?? SavedCell(id: id)
            cell.cellStyle = patch.applied(to: cell.cellStyle)
            changes.updateValue(cell.isEmpty ? nil : cell, forKey: id)
        }
        apply([activeSheetIndex: changes], name: name,
              tables: tables.map { [activeSheetIndex: $0] } ?? [:])
    }

    /// Epic 9 — "Clear formatting". Values are kept; ``clearSelection()`` is the other half.
    func clearFormatting() {
        applyStyle(.clearFormatting, name: "Clear Formatting")
    }

    /// Epic 9 — "Merge / unmerge".
    ///
    /// One command rather than two, matching the web app's single toolbar button: the selection
    /// either starts on a merge anchor, in which case the only sensible act is to split it, or it
    /// does not, in which case it is a range asking to be joined.
    func toggleMerge() {
        guard isEditable, let sheet = activeSheet, let selection else { return }

        if let origin = MergeEngine.mergeOrigin(at: selection.range.start, cells: sheet.cells) {
            // Selecting the whole block afterwards shows what was just split, which is otherwise
            // invisible — the cells look identical until you notice the borders.
            apply(MergeEngine.unmerge(origin, cells: sheet.cells), name: "Unmerge",
                  selectionAfter: SheetSelection(anchor: origin.start, active: origin.end))
        } else {
            let range = selection.range
            guard range.cellCount > 1 else { return }
            apply(MergeEngine.merge(range, cells: sheet.cells), name: "Merge",
                  selectionAfter: SheetSelection(range.start))
        }
    }

    /// Epic 9 — "Table style gallery and table regions".
    ///
    /// Applying a style does two things: it writes ordinary cell styles, which is what makes the
    /// banding visible in both clients, and it records a ``TableRegion``, which is what lets a
    /// client that understands structural edits re-band the range after a row is inserted. The
    /// "Blank" entry does the inverse of both.
    func applyTableStyle(_ style: TableStyle) {
        guard isEditable, let sheet = activeSheet, let selection else { return }
        let range = selection.range
        let existing = sheet.tables ?? []

        switch style.kind {
        case .blank:
            let patches = Dictionary(uniqueKeysWithValues:
                range.addresses.map { ($0.id, CellStylePatch.clearFormatting) })
            applyStyles(patches, name: "Clear Table Style",
                        tables: existing.removingOverlaps(with: range))

        case .regular(let regular):
            let region = TableRegion(id: TableRegion.makeID(), styleId: style.id, range: range)
            applyStyles(TableStyles.patches(for: regular, in: range), name: "Table Style",
                        tables: existing.registering(region))
        }
    }

    // MARK: - Fill

    /// Epic 8 — the fill handle. Extends the selection's cells across `target`, which must contain
    /// the selection and grow along one axis. See ``FillEngine``.
    func fill(to target: CellRange) {
        guard isEditable, let sheet = activeSheet, let selection else { return }
        let source = selection.range
        let changes = FillEngine.fill(source: source, target: target, cells: sheet.cells)
        guard !changes.isEmpty else { return }
        apply(changes, name: "Fill",
              selectionAfter: SheetSelection(anchor: target.start, active: target.end))
    }

    // MARK: - Clipboard

    /// Puts the selection on the pasteboard, as rich cells and as tab-separated text.
    ///
    /// - Parameter cut: records where the block came from so the next paste can clear it. Nothing
    ///   is removed here — see ``cutSource``.
    func copySelection(cut: Bool = false) {
        guard let sheet = activeSheet, let selection else { return }
        guard !cut || isEditable else { return }

        let range = selection.range
        let clipboard = SheetClipboard(range: range, cells: sheet.cells, isCut: cut)
        let payload = try? JSONEncoder().encode(clipboard)
        pasteboard.write(payload: payload, text: clipboard.tabSeparatedText)
        cutSource = cut ? (activeSheetIndex, range) : nil
        show(notice: cut ? "Cut \(range.address)" : "Copied \(range.address)")
    }

    /// Writes the clipboard into the selection.
    ///
    /// A selection larger than the copied block tiles it; a single-cell selection pastes the block
    /// at its own size. If the block was cut from this workbook, the source cells are cleared as
    /// part of the *same* edit, so one undo puts both ends back.
    func paste() {
        guard isEditable, let selection, let sheet = activeSheet else { return }
        guard let clipboard = readClipboard() else {
            show(notice: "Nothing to paste")
            return
        }

        let target = clipboard.target(at: selection.range.start, into: selection.range)
        let destination = clipboard.changes(at: selection.range.start, into: selection.range,
                                            existing: sheet.cells)
        guard !destination.isEmpty else { return }

        var bySheet: [Int: CellChanges] = [activeSheetIndex: destination]
        if clipboard.isCut, let cutSource {
            var cleared = CellChanges()
            for address in cutSource.range.addresses {
                // A block cut and pasted over itself must keep what the paste wrote, so the clear
                // only covers the cells the paste is not writing.
                if cutSource.sheetIndex == activeSheetIndex,
                   destination.index(forKey: address.id) != nil { continue }
                cleared.updateValue(nil, forKey: address.id)
            }
            bySheet[cutSource.sheetIndex] = bySheet[cutSource.sheetIndex]
                .map { $0.merging(cleared) { current, _ in current } } ?? cleared
        }

        apply(bySheet, name: "Paste",
              selectionAfter: SheetSelection(anchor: target.start, active: target.end))

        if clipboard.isCut {
            cutSource = nil
            pasteboard.write(payload: nil, text: clipboard.tabSeparatedText)
        }
        let pastedAFormula = destination.values.contains { cell in
            guard let raw = cell?.raw else { return false }
            return FormulaReferences.isFormula(raw)
        }
        if pastedAFormula {
            show(notice: "Pasted formulas recalculate when the sheet is opened on the web")
        }
    }

    /// Prefers this app's own payload, falling back to whatever text another app left.
    private func readClipboard() -> SheetClipboard? {
        if let payload = pasteboard.readPayload(),
           let clipboard = try? JSONDecoder().decode(SheetClipboard.self, from: payload) {
            return clipboard
        }
        guard let text = pasteboard.readText(), !text.isEmpty else { return nil }
        return SheetClipboard.fromTabSeparated(text)
    }

    // MARK: - Structure

    /// The rows and columns one structural command covers: the selection, or the active cell when
    /// there is no block selected.
    private var structuralTarget: CellRange? {
        selection?.range
    }

    /// Epic 10 — "Insert / delete rows and columns".
    ///
    /// As many rows go in as the selection covers, which is how every spreadsheet reads a selection
    /// of three rows and an "Insert above": three rows, not one. The cells, the row heights, the
    /// table regions and the conditional-format ranges all move together — see ``StructuralShift``.
    func insertRows(before: Bool) {
        guard let range = structuralTarget else { return }
        let index = before ? range.start.row : range.end.row + 1
        // Repeating the same index inserts the whole block in one place, rather than scattering the
        // new rows one apart from each other.
        shift(axis: .row, operation: .insert,
              indices: Array(repeating: index, count: range.rowCount),
              name: range.rowCount > 1 ? "Insert Rows" : "Insert Row",
              selectionAfter: SheetSelection(anchor: CellAddress(column: range.start.column, row: index),
                                             active: CellAddress(column: range.end.column,
                                                                 row: index + range.rowCount - 1)))
    }

    func insertColumns(before: Bool) {
        guard let range = structuralTarget else { return }
        let index = before ? range.start.column : range.end.column + 1
        shift(axis: .column, operation: .insert,
              indices: Array(repeating: index, count: range.columnCount),
              name: range.columnCount > 1 ? "Insert Columns" : "Insert Column",
              selectionAfter: SheetSelection(anchor: CellAddress(column: index, row: range.start.row),
                                             active: CellAddress(column: index + range.columnCount - 1,
                                                                 row: range.end.row)))
    }

    func deleteRows() {
        guard let range = structuralTarget else { return }
        // Descending, so removing one row never renumbers the ones still to go.
        shift(axis: .row, operation: .delete, indices: range.rows.reversed(),
              name: range.rowCount > 1 ? "Delete Rows" : "Delete Row",
              selectionAfter: SheetSelection(CellAddress(column: range.start.column,
                                                         row: range.start.row)))
    }

    func deleteColumns() {
        guard let range = structuralTarget else { return }
        shift(axis: .column, operation: .delete, indices: range.columns.reversed(),
              name: range.columnCount > 1 ? "Delete Columns" : "Delete Column",
              selectionAfter: SheetSelection(CellAddress(column: range.start.column,
                                                         row: range.start.row)))
    }

    private func shift(axis: StructuralAxis, operation: StructuralOperation, indices: [Int],
                       name: String, selectionAfter: SheetSelection?) {
        guard !indices.isEmpty else { return }
        editActiveSheet(name: name, selectionAfter: selectionAfter) { sheet in
            StructuralShift.apply(to: sheet, axis: axis, operation: operation, indices: indices)
        }
    }

    // MARK: - Sizes

    /// Epic 10 — "Resize columns and rows by drag", and the hide/show pair, which are the same
    /// write: a hidden column is one stored at zero width, which is what the web app does and what
    /// makes a column hidden here hidden there too.
    ///
    /// - Parameter width: nil removes the override, putting the column back to the default width.
    func resize(columns: ClosedRange<Int>, to width: Double?, name: String = "Resize Column") {
        editActiveSheet(name: name) { sheet in
            var updated = sheet
            var widths = sheet.colWidths ?? [:]
            for column in columns {
                let key = String(column - 1)
                if let width { widths[key] = max(0, width) } else { widths.removeValue(forKey: key) }
            }
            updated.colWidths = widths.isEmpty ? nil : widths
            return updated
        }
    }

    func resize(rows: ClosedRange<Int>, to height: Double?, name: String = "Resize Row") {
        editActiveSheet(name: name) { sheet in
            var updated = sheet
            var heights = sheet.rowHeights ?? [:]
            for row in rows {
                let key = String(row - 1)
                if let height { heights[key] = max(0, height) } else { heights.removeValue(forKey: key) }
            }
            updated.rowHeights = heights.isEmpty ? nil : heights
            return updated
        }
    }

    /// Epic 10 — "Hide / show".
    func hideRows() {
        guard let range = structuralTarget else { return }
        resize(rows: range.rows, to: 0, name: range.rowCount > 1 ? "Hide Rows" : "Hide Row")
    }

    func hideColumns() {
        guard let range = structuralTarget else { return }
        resize(columns: range.columns, to: 0,
               name: range.columnCount > 1 ? "Hide Columns" : "Hide Column")
    }

    /// Whether anything inside the selection is hidden, so the menu can offer to show it.
    var selectionHasHiddenRowsOrColumns: Bool {
        guard let range = structuralTarget, let sheet = activeSheet else { return false }
        return range.rows.contains { sheet.height(ofRow: $0 - 1) == 0 }
            || range.columns.contains { sheet.width(ofColumn: $0 - 1) == 0 }
    }

    /// Puts back anything hidden inside the selection.
    ///
    /// Reachable because a hidden row still has an index: dragging a selection across the gap
    /// covers it, even though it draws nothing. ``showEverything()`` is the way out for a user who
    /// cannot find the gap.
    func showSelection() {
        guard let range = structuralTarget, let sheet = activeSheet else { return }
        let rows = range.rows.filter { sheet.height(ofRow: $0 - 1) == 0 }
        let columns = range.columns.filter { sheet.width(ofColumn: $0 - 1) == 0 }
        guard !rows.isEmpty || !columns.isEmpty else { return }

        editActiveSheet(name: "Show") { sheet in
            var updated = sheet
            var heights = sheet.rowHeights ?? [:]
            for row in rows { heights.removeValue(forKey: String(row - 1)) }
            var widths = sheet.colWidths ?? [:]
            for column in columns { widths.removeValue(forKey: String(column - 1)) }
            updated.rowHeights = heights.isEmpty ? nil : heights
            updated.colWidths = widths.isEmpty ? nil : widths
            return updated
        }
    }

    /// Whether the active tab hides anything at all.
    var hasHiddenRowsOrColumns: Bool {
        guard let sheet = activeSheet else { return false }
        return (sheet.rowHeights ?? [:]).values.contains(0) || (sheet.colWidths ?? [:]).values.contains(0)
    }

    /// Restores every hidden row and column on the active tab.
    func showEverything() {
        editActiveSheet(name: "Show All") { sheet in
            var updated = sheet
            let heights = (sheet.rowHeights ?? [:]).filter { $0.value != 0 }
            let widths = (sheet.colWidths ?? [:]).filter { $0.value != 0 }
            updated.rowHeights = heights.isEmpty ? nil : heights
            updated.colWidths = widths.isEmpty ? nil : widths
            return updated
        }
    }

    // MARK: - Sorting

    /// Epic 10 — "Sort a range or a column".
    ///
    /// What gets sorted depends on the selection, the way it does in Excel:
    ///
    /// - a block spanning more than one column and more than one row sorts **within itself**;
    /// - anything else — a single cell, or a whole column picked from its header — sorts the tab's
    ///   entire used range by that column, so the rows stay together. Sorting one column in
    ///   isolation would shuffle it out of step with the data beside it, which is not a sort of
    ///   anything, it is a shredder.
    func sort(by column: Int, ascending: Bool) {
        guard isEditable, let sheet = activeSheet, let selection else { return }

        let range: CellRange
        if selection.range.columnCount > 1 && selection.range.rowCount > 1 {
            range = selection.range
        } else {
            guard let used = sheet.usedBounds else { return }
            range = CellRange(CellAddress(column: 1, row: 1),
                              CellAddress(column: max(used.columns, column), row: used.rows))
        }

        switch SortEngine.sortRows(in: range, by: column, ascending: ascending, cells: sheet.cells) {
        case .success(let changes):
            guard !changes.isEmpty else { return }
            apply(changes, name: "Sort")
        case .failure(.containsMergedCells):
            show(notice: "Cannot sort a range that contains merged cells")
        case .failure(.nothingToSort):
            break
        }
    }

    // MARK: - Filtering

    /// Epic 10 — "Per-column filters". Not written to the file; see ``ColumnFilters``.
    @Published var columnFilters = ColumnFilters()

    /// How far down the tab holds anything — the bound on every whole-column walk.
    var usedRowCount: Int { activeSheet?.usedBounds?.rows ?? 0 }

    /// The rows the active filters hide, which the grid lays out at zero height.
    var filteredRows: Set<Int> {
        guard let sheet = activeSheet else { return [] }
        return columnFilters.hiddenRows(in: sheet.cells, rows: usedRowCount)
    }

    /// The distinct entries in a column, for the filter list.
    func filterValues(inColumn column: Int) -> [String] {
        guard let sheet = activeSheet else { return [] }
        return ColumnFilters.values(inColumn: column, cells: sheet.cells, rows: usedRowCount)
    }

    func setFilter(_ values: Set<String>?, forColumn column: Int) {
        columnFilters.set(values, forColumn: column)
    }

    func clearAllFilters() {
        columnFilters.removeAll()
    }

    // MARK: - Find & replace

    /// Epic 10 — "Find & replace". The dialog owns the query; the workbook is read here.
    func matches(for query: String, options: FindReplace.Options) -> [CellAddress] {
        guard let sheet = activeSheet else { return [] }
        return FindReplace.matches(in: sheet.cells, query: query, options: options)
    }

    /// Replaces the first occurrence in one cell.
    func replace(at address: CellAddress, query: String, with replacement: String,
                 options: FindReplace.Options) {
        guard isEditable, let sheet = activeSheet, let cell = sheet.cells[address.id] else { return }
        var changes = CellChanges()
        changes.updateValue(FindReplace.replaced(cell, query: query, with: replacement,
                                                 options: options, all: false),
                            forKey: address.id)
        apply(changes, name: "Replace", selectionAfter: SheetSelection(address))
        noteFormulaRewrite(in: [cell])
    }

    /// Replaces every occurrence everywhere on the active tab, as one edit.
    ///
    /// - Returns: how many cells changed, for the confirmation the dialog shows.
    @discardableResult
    func replaceAll(query: String, with replacement: String,
                    options: FindReplace.Options) -> Int {
        guard isEditable, let sheet = activeSheet else { return 0 }
        let addresses = FindReplace.matches(in: sheet.cells, query: query, options: options)
        guard !addresses.isEmpty else { return 0 }

        var changes = CellChanges()
        var touched: [SavedCell] = []
        for address in addresses {
            guard let cell = sheet.cells[address.id] else { continue }
            touched.append(cell)
            changes.updateValue(FindReplace.replaced(cell, query: query, with: replacement,
                                                     options: options, all: true),
                                forKey: address.id)
        }
        apply(changes, name: "Replace All")
        noteFormulaRewrite(in: touched)
        return changes.count
    }

    /// Says so when a replacement rewrote a formula, because its stored result was dropped with it —
    /// the same rule, and the same wording, as a pasted formula in Epic 8.
    private func noteFormulaRewrite(in cells: [SavedCell]) {
        guard cells.contains(where: { FormulaReferences.isFormula($0.raw ?? "") }) else { return }
        show(notice: "Replaced formulas recalculate when the sheet is opened on the web")
    }

    // MARK: - Freeze panes

    /// Epic 10 — "Freeze panes", per tab.
    ///
    /// Held in memory rather than written to the workbook, and that is the whole decision: the
    /// format has no field for it. The web app has no freeze either, so there is nothing to agree
    /// with — inventing a key would put something in a shared file that the browser ignores today
    /// and a later web release might claim for something else.
    private var frozenByTab: [Int: FrozenPanes] = [:]

    var frozen: FrozenPanes {
        frozenByTab[activeSheetIndex] ?? FrozenPanes()
    }

    /// Freezes everything above and left of the selection's active cell.
    func freezeToSelection() {
        guard let active = selection?.active else { return }
        let panes = FrozenPanes(rows: active.row - 1, columns: active.column - 1)
        frozenByTab[activeSheetIndex] = panes.isEmpty ? nil : panes
        objectWillChange.send()
        show(notice: panes.isEmpty ? "Panes unfrozen" : "Frozen \(panes.description)")
    }

    func unfreeze() {
        guard frozenByTab[activeSheetIndex] != nil else { return }
        frozenByTab.removeValue(forKey: activeSheetIndex)
        objectWillChange.send()
    }

    // MARK: - Tabs

    /// Epic 10 — "Add / rename / colour / reorder / duplicate / delete sheet tabs".
    ///
    /// Every one of these is a change to the tab list, so they all travel as a ``WorkbookEdit``
    /// snapshot and all undo in one step.
    func addSheet() {
        guard let file else { return }
        let outcome = SheetTabs.add(to: file.sheets)
        applyWorkbook(outcome.sheets, name: "Add Sheet", activeIndexAfter: outcome.activeIndex,
                      selectionAfter: SheetSelection(CellAddress(column: 1, row: 1)))
    }

    func renameSheet(at index: Int, to name: String) {
        guard let file else { return }
        applyWorkbook(SheetTabs.rename(file.sheets, at: index, to: name), name: "Rename Sheet")
    }

    func setSheetColor(_ color: String?, at index: Int) {
        guard let file else { return }
        applyWorkbook(SheetTabs.setColor(file.sheets, at: index, to: color), name: "Sheet Colour")
    }

    func duplicateSheet(at index: Int) {
        guard let file else { return }
        let outcome = SheetTabs.duplicate(file.sheets, at: index)
        forgetFrozenPanes()
        applyWorkbook(outcome.sheets, name: "Duplicate Sheet", activeIndexAfter: outcome.activeIndex,
                      selectionAfter: SheetSelection(CellAddress(column: 1, row: 1)))
    }

    /// Whether deleting is offered at all — a workbook has to keep one tab.
    var canDeleteSheet: Bool { (file?.sheets.count ?? 0) > 1 }

    func deleteSheet(at index: Int) {
        guard let file,
              let outcome = SheetTabs.delete(file.sheets, at: index, activeIndex: activeSheetIndex)
        else { return }
        forgetFrozenPanes()
        applyWorkbook(outcome.sheets, name: "Delete Sheet", activeIndexAfter: outcome.activeIndex,
                      selectionAfter: SheetSelection(CellAddress(column: 1, row: 1)))
    }

    func moveSheet(at index: Int, by offset: Int) {
        guard let file,
              let outcome = SheetTabs.move(file.sheets, from: index, by: offset,
                                           activeIndex: activeSheetIndex) else { return }
        forgetFrozenPanes()
        applyWorkbook(outcome.sheets, name: "Move Sheet", activeIndexAfter: outcome.activeIndex)
    }

    /// Drops the frozen panes when the tab list is rearranged.
    ///
    /// They are keyed by tab index, and a reorder or a delete renumbers those indices — carrying
    /// them across would freeze the wrong tab. Re-freezing is two taps, and freezing a tab the user
    /// never asked to freeze is a grid that will not scroll for reasons nobody can see.
    private func forgetFrozenPanes() {
        guard !frozenByTab.isEmpty else { return }
        frozenByTab.removeAll()
        objectWillChange.send()
    }

    /// Moves to another tab, resetting the selection to its top-left cell.
    func selectSheet(at index: Int) {
        guard file?.sheets.indices.contains(index) == true, index != activeSheetIndex else { return }
        activeSheetIndex = index
        selection = SheetSelection(CellAddress(column: 1, row: 1))
        // Filters name columns of the tab they were made on; carrying them to another tab would
        // hide rows for reasons the user could not see there.
        columnFilters.removeAll()
    }

    // MARK: - Undo / redo

    func undo() {
        guard let edit = history.undo() else { return }
        restore(edit, undoing: true)
    }

    func redo() {
        guard let edit = history.redo() else { return }
        restore(edit, undoing: false)
    }

    /// Puts one side of an edit back, whichever shape it was recorded in.
    private func restore(_ edit: WorkbookEdit, undoing: Bool) {
        switch edit.change {
        case .cells(let before, let after, let tablesBefore, let tablesAfter):
            write(undoing ? before : after, tables: undoing ? tablesBefore : tablesAfter)
        case .workbook(let before, let after):
            if var updatedFile = file {
                updatedFile.sheets = undoing ? before : after
                file = updatedFile
            }
        }
        // Clamped, because a tab index recorded before a delete can point past the end of the list
        // the other side of the edit restores.
        activeSheetIndex = min(max(0, undoing ? edit.sheetBefore : edit.sheetAfter),
                               max(0, (file?.sheets.count ?? 1) - 1))
        selection = undoing ? edit.selectionBefore : edit.selectionAfter
        historyToken &+= 1
        hasUnsavedChanges = true
    }

    // MARK: - Applying changes

    /// The single funnel every edit passes through.
    ///
    /// Reads the cells being written *before* writing them, so the undo entry costs one dictionary
    /// lookup per changed cell rather than a copy of the tab. A change that writes what is already
    /// there is dropped, which keeps a no-op edit — retyping the same value, pasting a block over
    /// its own copy — out of the history and off the save queue.
    private func apply(_ changes: CellChanges, name: String, selectionAfter: SheetSelection? = nil) {
        apply([activeSheetIndex: changes], name: name, selectionAfter: selectionAfter)
    }

    /// - Parameter tables: the ``TableRegion`` list a tab should end up with, for the edits that
    ///   change it. A tab absent from the map keeps whatever it had.
    private func apply(_ changes: [Int: CellChanges], name: String,
                       tables: [Int: [TableRegion]] = [:],
                       selectionAfter: SheetSelection? = nil) {
        guard isEditable, var file else { return }

        var before: [Int: CellChanges] = [:]
        var after: [Int: CellChanges] = [:]

        for (sheetIndex, sheetChanges) in changes {
            guard file.sheets.indices.contains(sheetIndex) else { continue }
            var sheet = file.sheets[sheetIndex]
            var sheetBefore = CellChanges()
            var sheetAfter = CellChanges()

            for (id, newCell) in sheetChanges {
                let oldCell = sheet.cells[id]
                guard oldCell != newCell else { continue }
                sheetBefore.updateValue(oldCell, forKey: id)
                sheetAfter.updateValue(newCell, forKey: id)
                if let newCell {
                    sheet.cells[id] = newCell
                } else {
                    sheet.cells.removeValue(forKey: id)
                }
            }

            guard !sheetAfter.isEmpty else { continue }
            file.sheets[sheetIndex] = sheet
            before[sheetIndex] = sheetBefore
            after[sheetIndex] = sheetAfter
        }

        var tablesBefore: [Int: [TableRegion]] = [:]
        var tablesAfter: [Int: [TableRegion]] = [:]
        for (sheetIndex, regions) in tables {
            guard file.sheets.indices.contains(sheetIndex) else { continue }
            let current = file.sheets[sheetIndex].tables ?? []
            guard current != regions else { continue }
            tablesBefore[sheetIndex] = current
            tablesAfter[sheetIndex] = regions
            // An empty list is written back as an absent key, so a workbook that never had tables
            // does not gain `"tables":[]` the first time one is cleared.
            file.sheets[sheetIndex].tables = regions.isEmpty ? nil : regions
        }

        // A table style whose colours are already on the cells still has a region to record, so
        // "nothing changed" has to mean neither half changed.
        guard !after.isEmpty || !tablesAfter.isEmpty else { return }
        self.file = file

        history.record(WorkbookEdit(change: .cells(before: before, after: after,
                                                   tablesBefore: tablesBefore,
                                                   tablesAfter: tablesAfter),
                                    sheetBefore: activeSheetIndex, sheetAfter: activeSheetIndex,
                                    selectionBefore: selection,
                                    selectionAfter: selectionAfter ?? selection,
                                    name: name))
        historyToken &+= 1
        if let selectionAfter { selection = selectionAfter }
        hasUnsavedChanges = true
    }

    /// Epic 10 — the funnel for an edit that rearranges the workbook rather than patching cells.
    ///
    /// A structural edit, a resize and every tab operation come through here. They are recorded as a
    /// snapshot of the tab list because that is what they are: a row insert moves every cell below
    /// it, and a tab reorder is not a change to cells at all. See ``WorkbookEdit/Change``.
    private func applyWorkbook(_ sheets: [SheetData], name: String, activeIndexAfter: Int? = nil,
                               selectionAfter: SheetSelection? = nil) {
        guard isEditable, var file, file.sheets != sheets else { return }
        let before = file.sheets
        let sheetAfter = min(max(0, activeIndexAfter ?? activeSheetIndex), max(0, sheets.count - 1))

        file.sheets = sheets
        self.file = file

        history.record(WorkbookEdit(change: .workbook(before: before, after: sheets),
                                    sheetBefore: activeSheetIndex, sheetAfter: sheetAfter,
                                    selectionBefore: selection,
                                    selectionAfter: selectionAfter ?? selection,
                                    name: name))
        historyToken &+= 1
        activeSheetIndex = sheetAfter
        if let selectionAfter { selection = selectionAfter }
        hasUnsavedChanges = true
    }

    /// Runs `transform` over the active tab and records the result. Nil backs out with no edit.
    private func editActiveSheet(name: String, selectionAfter: SheetSelection? = nil,
                                 _ transform: (SheetData) -> SheetData?) {
        guard isEditable, let file, let sheet = activeSheet,
              let updated = transform(sheet) else { return }
        var sheets = file.sheets
        sheets[activeSheetIndex] = updated
        applyWorkbook(sheets, name: name, selectionAfter: selectionAfter)
    }

    /// Writes cells without recording history — the undo and redo path.
    private func write(_ changes: [Int: CellChanges], tables: [Int: [TableRegion]] = [:]) {
        guard var file else { return }
        for (sheetIndex, sheetChanges) in changes {
            guard file.sheets.indices.contains(sheetIndex) else { continue }
            var sheet = file.sheets[sheetIndex]
            for (id, cell) in sheetChanges {
                if let cell {
                    sheet.cells[id] = cell
                } else {
                    sheet.cells.removeValue(forKey: id)
                }
            }
            file.sheets[sheetIndex] = sheet
        }
        for (sheetIndex, regions) in tables {
            guard file.sheets.indices.contains(sheetIndex) else { continue }
            file.sheets[sheetIndex].tables = regions.isEmpty ? nil : regions
        }
        self.file = file
    }

    // MARK: - Notices

    private func show(notice message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Saving

    /// Queues a save behind whatever is already in flight.
    ///
    /// Every path into saving goes through here — the timer, the manual save, and the
    /// leaving-the-editor flush — because that is the only way to be sure two PUTs are never on the
    /// wire at once.
    func queueSave() {
        guard !isSaveQueued else { return }
        isSaveQueued = true
        let previous = saveChain
        saveChain = Task { [weak self] in
            await previous?.value
            await self?.performSave()
        }
    }

    /// Saves if anything has changed. The autosave timer calls this.
    func saveIfNeeded() {
        guard hasUnsavedChanges, conflict == nil else { return }
        queueSave()
    }

    /// Waits for every queued save to finish. Called when the editor is going away, so an edit made
    /// a moment before leaving is not lost.
    func flush() async {
        saveIfNeeded()
        await saveChain?.value
    }

    private func performSave() async {
        // Released here rather than at the end: from this point the save is reading current state,
        // so an edit that lands during the upload does need a save of its own.
        isSaveQueued = false
        guard let file, let dek, isEditable else { return }
        // A conflict is unresolved until the user says otherwise; saving over it is exactly what
        // must not happen.
        guard conflict == nil else { return }

        isSaving = true
        saveError = nil
        defer { isSaving = false }

        // Cleared *before* the request, not after: an edit made while the upload is in flight has
        // to leave the flag set, and clearing afterwards would swallow it.
        hasUnsavedChanges = false

        do {
            let result = try await contentService.save(file, to: item.id, dek: dek,
                                                       expectedContentVersion: contentVersion,
                                                       keeping: sourcePackage)
            contentVersion = result.contentVersion
            needsInitialEncryption = false
            previewer?.saved(file, hasPreview: result.hasPreview)
            driveService?.spreadsheetWasSaved(itemID: item.id, size: result.sizeBytes,
                                              modifiedAt: result.updatedAt,
                                              contentVersion: result.contentVersion)
            logger.debug("save succeeded: id=\(self.item.id, privacy: .public)")
        } catch let error as SheetContentError {
            hasUnsavedChanges = true
            if case .contentVersionConflict(let current) = error {
                logger.error("save conflict: id=\(self.item.id, privacy: .public)")
                conflict = ConflictState(serverVersion: current)
            } else {
                logger.error("save failed: \(error, privacy: .public)")
                saveError = error.localizedDescription
            }
        } catch {
            hasUnsavedChanges = true
            logger.error("save failed: \(error, privacy: .public)")
            saveError = error.localizedDescription
        }
    }

    /// Replaces an offline copy with the server's workbook, once there is a connection. Nothing to
    /// lose: an offline copy cannot be edited.
    func reloadFromServer() async {
        guard offlineCopyDate != nil, !isLoading else { return }
        file = nil
        history.clear()
        historyToken &+= 1
        await load()
    }

    // MARK: - Conflict resolution

    /// Throws away this device's edits and re-reads the server's copy.
    func reloadAfterConflict() async {
        conflict = nil
        file = nil
        hasUnsavedChanges = false
        // The history describes cells that are about to be replaced wholesale; undoing into them
        // afterwards would write this device's discarded edits back over the server's copy.
        history.clear()
        historyToken &+= 1
        await load()
    }

    /// Keeps this device's copy, overwriting whatever landed on the server.
    ///
    /// Done by dropping the version guard for one save: the point of `expectedContentVersion` is to
    /// stop an *unintended* overwrite, and this one is intended.
    func keepLocalCopyAfterConflict() {
        guard let serverVersion = conflict?.serverVersion else {
            // Without the server's version there is nothing to guard against, so the save goes
            // unguarded — which is what the user just asked for.
            contentVersion = nil
            conflict = nil
            queueSave()
            return
        }
        contentVersion = serverVersion
        conflict = nil
        queueSave()
    }
}
