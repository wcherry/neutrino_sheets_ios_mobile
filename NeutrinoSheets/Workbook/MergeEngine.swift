import Foundation

// MARK: - MergeEngine

/// Epic 9 — "Merge / unmerge".
///
/// A port of `mergeCells` in the web app's `hooks/useCellEditing.ts`, kept pure so the same rules
/// can be tested without a workbook, a selection or a view.
///
/// A merge is stored on the cells themselves rather than as a list of regions: the **anchor** — the
/// top-left cell — carries `colSpan` / `rowSpan`, and every cell it covers carries `mergeAnchor`
/// pointing back at it. The covered cells keep whatever they held, so unmerging restores the block
/// exactly. Excel throws those values away; the web app does not, and the format is the contract.
enum MergeEngine {

    // MARK: - Queries

    /// The block anchored at `address`, or nil when that cell is not a merge origin.
    static func mergeOrigin(at address: CellAddress, cells: [String: SavedCell]) -> CellRange? {
        guard let cell = cells[address.id] else { return nil }
        let columns = cell.colSpan ?? 1
        let rows = cell.rowSpan ?? 1
        guard columns > 1 || rows > 1 else { return nil }
        return CellRange(address, address.offset(columns: columns - 1, rows: rows - 1))
    }

    // MARK: - Merging

    /// Merges `range` into its top-left cell.
    ///
    /// Any merge already inside the range is absorbed: a covered cell is written with the new
    /// anchor and no span of its own, so a block that used to be an origin cannot go on claiming
    /// cells the new merge now owns.
    ///
    /// Returns no changes for a single cell — there is nothing to merge, and recording an edit that
    /// changed nothing would put an empty step in the undo history.
    static func merge(_ range: CellRange, cells: [String: SavedCell]) -> CellChanges {
        guard range.cellCount > 1 else { return [:] }
        let anchorID = range.start.id

        var changes = CellChanges()
        var anchor = cells[anchorID] ?? SavedCell(id: anchorID)
        anchor.colSpan = range.columnCount
        anchor.rowSpan = range.rowCount
        anchor.mergeAnchor = nil
        changes.updateValue(anchor, forKey: anchorID)

        for address in range.addresses where address.id != anchorID {
            var cell = cells[address.id] ?? SavedCell(id: address.id)
            cell.mergeAnchor = anchorID
            cell.colSpan = nil
            cell.rowSpan = nil
            changes.updateValue(cell, forKey: address.id)
        }
        return changes
    }

    // MARK: - Unmerging

    /// Splits the block anchored at `range.start` back into individual cells.
    ///
    /// A covered cell that held nothing of its own becomes empty again and is removed rather than
    /// stored as `{"id":"B2"}`, which is what the web app's serialiser would drop anyway.
    static func unmerge(_ range: CellRange, cells: [String: SavedCell]) -> CellChanges {
        let anchorID = range.start.id
        var changes = CellChanges()

        if var anchor = cells[anchorID] {
            anchor.colSpan = nil
            anchor.rowSpan = nil
            changes.updateValue(anchor.isEmpty ? nil : anchor, forKey: anchorID)
        }

        for address in range.addresses where address.id != anchorID {
            guard var cell = cells[address.id] else { continue }
            cell.mergeAnchor = nil
            changes.updateValue(cell.isEmpty ? nil : cell, forKey: address.id)
        }
        return changes
    }
}
