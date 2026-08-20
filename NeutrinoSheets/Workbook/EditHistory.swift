import Foundation

// MARK: - WorkbookEdit

/// One undoable change to a workbook.
///
/// Recorded as the cells that changed rather than as a copy of the whole tab: a snapshot of a
/// 10,000-cell sheet per keystroke is megabytes of history for a two-character edit, and the phone
/// is the wrong place to find that out. Both halves are kept — `before` to undo with, `after` to
/// redo with — so neither direction has to reconstruct anything.
///
/// The selection travels with the edit for the same reason a text editor restores the caret:
/// undoing a paste that landed off-screen is disorienting if the grid does not go back to it.
struct WorkbookEdit {

    /// The cells as they were, keyed by tab index. A `nil` cell means it did not exist.
    ///
    /// Keyed by tab rather than carrying a single index because one edit really can touch two:
    /// cutting from one sheet and pasting into another clears the source and writes the
    /// destination, and undo has to put both back or it puts back neither.
    let before: [Int: CellChanges]
    /// The cells as the edit left them.
    let after: [Int: CellChanges]

    /// Epic 9 — a tab's whole ``TableRegion`` list, before and after, for the edits that change it.
    ///
    /// Whole lists rather than per-region patches because the list is short — a workbook has a
    /// handful of tables, not thousands — and because applying a table style *replaces* whatever it
    /// overlaps, which is a change to the list as a unit. Absent for every edit that touches only
    /// cells, which is nearly all of them.
    let tablesBefore: [Int: [TableRegion]]
    let tablesAfter: [Int: [TableRegion]]

    /// The tab that was showing before the edit, and the one to show after it — so undoing a paste
    /// made on another tab takes you back to where it happened rather than silently rewriting
    /// cells you cannot see.
    let sheetBefore: Int
    let sheetAfter: Int

    let selectionBefore: SheetSelection?
    let selectionAfter: SheetSelection?

    /// A label for the menu item, e.g. "Undo Paste".
    let name: String

    init(before: [Int: CellChanges], after: [Int: CellChanges],
         tablesBefore: [Int: [TableRegion]] = [:], tablesAfter: [Int: [TableRegion]] = [:],
         sheetBefore: Int, sheetAfter: Int,
         selectionBefore: SheetSelection?, selectionAfter: SheetSelection?,
         name: String) {
        self.before = before
        self.after = after
        self.tablesBefore = tablesBefore
        self.tablesAfter = tablesAfter
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

    /// Moves one edit onto the redo stack and hands it back. The caller applies its `before`.
    mutating func undo() -> WorkbookEdit? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit)
        return edit
    }

    /// The inverse. The caller applies the returned edit's `after`.
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
