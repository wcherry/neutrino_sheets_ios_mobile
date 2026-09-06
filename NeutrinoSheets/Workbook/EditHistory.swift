import Foundation

// MARK: - WorkbookEdit

/// One undoable change to a workbook.
///
/// The selection travels with the edit for the same reason a text editor restores the caret: undoing
/// a paste that landed off-screen is disorienting if the grid does not go back to it.
struct WorkbookEdit {

    // MARK: - Change

    /// What actually changed, in one of the two shapes an edit can take.
    ///
    /// Two, and not one, because the two kinds of edit have opposite cost profiles. A typed value
    /// touches one cell out of ten thousand, so recording it as a snapshot of the tab would be
    /// megabytes of history for a two-character edit. A row insert moves *every cell below it*, so
    /// recording that as a per-cell patch would be the same snapshot with extra bookkeeping — and it
    /// still could not describe a tab being deleted or reordered, which is not a change to cells at
    /// all.
    ///
    /// The snapshot is cheaper than it looks: `SheetData` is a value type, so the tabs an edit did
    /// not touch share storage with the ones already held, and only the edited tab's cell
    /// dictionary is actually copied.
    enum Change {
        /// Cells, keyed by tab index. A `nil` cell means it did not exist.
        ///
        /// Keyed by tab rather than carrying a single index because one edit really can touch two:
        /// cutting from one sheet and pasting into another clears the source and writes the
        /// destination, and undo has to put both back or it puts back neither.
        ///
        /// `tables` carries a tab's whole ``TableRegion`` list for the edits that change it — whole
        /// lists rather than per-region patches, because applying a table style *replaces* whatever
        /// it overlaps, which is a change to the list as a unit. Absent for every edit that touches
        /// only cells, which is nearly all of them.
        case cells(before: [Int: CellChanges], after: [Int: CellChanges],
                   tablesBefore: [Int: [TableRegion]] = [:], tablesAfter: [Int: [TableRegion]] = [:])

        /// Epic 10 — the whole tab list, before and after. Structural edits, resizes and every tab
        /// operation.
        case workbook(before: [SheetData], after: [SheetData])
    }

    let change: Change

    /// The tab that was showing before the edit, and the one to show after it — so undoing a paste
    /// made on another tab takes you back to where it happened rather than silently rewriting cells
    /// you cannot see.
    let sheetBefore: Int
    let sheetAfter: Int

    let selectionBefore: SheetSelection?
    let selectionAfter: SheetSelection?

    /// A label for the menu item, e.g. "Undo Paste".
    let name: String

    init(change: Change, sheetBefore: Int, sheetAfter: Int,
         selectionBefore: SheetSelection?, selectionAfter: SheetSelection?, name: String) {
        self.change = change
        self.sheetBefore = sheetBefore
        self.sheetAfter = sheetAfter
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.name = name
    }
}

// MARK: - EditHistory

/// Epic 8 — "Undo / redo".
///
/// A plain pair of stacks, capped at the web app's `MAX_HISTORY`. Recording a new edit clears the
/// redo stack, which is the rule every editor follows: once you have changed the future, the old
/// one is not reachable any more.
struct EditHistory {

    /// `MAX_HISTORY` from the web app's `editor/constants.ts`, so the two clients forget at the
    /// same depth.
    static let limit = 100

    private(set) var undoStack: [WorkbookEdit] = []
    private(set) var redoStack: [WorkbookEdit] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// The name of the edit undo would reverse, for the menu item.
    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    /// Files an edit that has already been applied.
    mutating func record(_ edit: WorkbookEdit) {
        undoStack.append(edit)
        if undoStack.count > Self.limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Moves one edit onto the redo stack and hands it back. The caller applies its "before" side.
    mutating func undo() -> WorkbookEdit? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit)
        return edit
    }

    /// The inverse. The caller applies the returned edit's "after" side.
    mutating func redo() -> WorkbookEdit? {
        guard let edit = redoStack.popLast() else { return nil }
        undoStack.append(edit)
        return edit
    }

    /// Throws the history away — after a reload, when the cells it refers to are no longer the
    /// ones on screen.
    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
