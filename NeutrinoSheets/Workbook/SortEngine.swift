import Foundation

// MARK: - SortEngine

/// Epic 10 — "Sort a range or a column".
///
/// A port of `handleSortByCol` / `compareValues` in the web app's `SheetEditor.tsx`. Sorting moves
/// whole rows, carrying every cell across with its styles: a table sorted by one column with the
/// other columns left where they were is not a sort, it is data loss with extra steps.
///
/// The comparison rules are the web app's, including the one that looks arbitrary — **blanks always
/// sort last**, in both directions. In the browser that guards against a phantom blank the cursor
/// leaves behind; here it is kept because a shared file sorted on two clients must come out in the
/// same order, and because it is the behaviour a spreadsheet user expects anyway.
enum SortEngine {

    // MARK: - Comparing

    /// Orders two cell values the way the web app's `compareValues` does.
    ///
    /// Numeric when *both* sides parse as numbers, and a case-insensitive text comparison otherwise
    /// — so `9` sorts before `10` in a numeric column, and `Apple` next to `apple` in a text one.
    /// ``CellFormatter/parseNumber(_:)`` is used rather than `Double(_:)` because the web app uses
    /// `parseFloat`, which takes a leading numeric prefix: `"12kg"` is 12 to the browser, and a
    /// column of those has to sort the same in both clients.
    static func compare(_ a: String, _ b: String, ascending: Bool) -> ComparisonResult {
        if a.isEmpty && !b.isEmpty { return .orderedDescending }
        if b.isEmpty && !a.isEmpty { return .orderedAscending }

        let result: ComparisonResult
        if let left = CellFormatter.parseNumber(a), let right = CellFormatter.parseNumber(b) {
            result = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        } else {
            result = a.compare(b, options: [.caseInsensitive, .diacriticInsensitive])
        }

        guard !ascending, result != .orderedSame else { return result }
        return result == .orderedAscending ? .orderedDescending : .orderedAscending
    }

    /// What a row is sorted on: the display value, falling back to what was typed.
    private static func key(_ cell: SavedCell?) -> String {
        cell?.value ?? cell?.raw ?? ""
    }

    // MARK: - Sorting

    /// Why a sort was refused, so the caller can say something better than nothing.
    enum Refusal: Error, Equatable {
        /// The range holds a merged block. Sorting one would move an anchor away from the cells it
        /// covers, leaving `mergeAnchor` pointers aimed at cells that no longer exist — a workbook
        /// the web app cannot render and no undo the user reaches for would obviously fix. Excel
        /// refuses this too, and for the same reason.
        case containsMergedCells
        /// One row, or none. There is nothing to reorder.
        case nothingToSort
    }

    /// Reorders the rows of `range` by the values in `column`.
    ///
    /// Only cells **inside** `range` move, which is what makes this both "sort a range" and "sort a
    /// column": sorting a column passes the tab's whole used extent, and sorting a selected block
    /// passes the block.
    ///
    /// - Parameter column: 1-based, and must fall inside `range`.
    /// - Returns: the cells to write, or the reason nothing can be written.
    static func sortRows(in range: CellRange, by column: Int, ascending: Bool,
                         cells: [String: SavedCell]) -> Result<CellChanges, Refusal> {
        guard range.rowCount > 1 else { return .failure(.nothingToSort) }
        guard range.columns.contains(column) else { return .failure(.nothingToSort) }

        // Merges are checked across the whole block rather than just the key column: a merge
        // anywhere in the range spans rows that are about to be separated.
        for address in range.addresses {
            guard let cell = cells[address.id] else { continue }
            if (cell.colSpan ?? 1) > 1 || (cell.rowSpan ?? 1) > 1 || cell.mergeAnchor != nil {
                return .failure(.containsMergedCells)
            }
        }

        // Each row is captured as its cells keyed by column, so a row can be written back at a
        // different row number without touching the columns it occupies.
        var rows: [(key: String, cells: [Int: SavedCell])] = []
        rows.reserveCapacity(range.rowCount)
        for row in range.rows {
            var occupants: [Int: SavedCell] = [:]
            for index in range.columns {
                if let cell = cells[CellAddress(column: index, row: row).id] {
                    occupants[index] = cell
                }
            }
            rows.append((key: key(occupants[column]), cells: occupants))
        }

        // A stable sort, so rows sharing a key keep the order they were in — Swift's `sort` is not
        // stable, and an unstable sort makes a second sort on the same column reshuffle equal rows
        // for no visible reason.
        let order = rows.enumerated().sorted { left, right in
            switch compare(left.element.key, right.element.key, ascending: ascending) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:       return left.offset < right.offset
            }
        }
        guard order.map(\.offset) != Array(order.indices) else { return .success([:]) }

        var changes = CellChanges()
        for (position, entry) in order.enumerated() {
            let row = range.start.row + position
            for index in range.columns {
                let id = CellAddress(column: index, row: row).id
                guard var cell = entry.element.cells[index] else {
                    // The row that landed here has nothing in this column, so whatever was there
                    // before has to go — otherwise a sort leaves stale values behind in the gaps.
                    if cells[id] != nil { changes.updateValue(nil, forKey: id) }
                    continue
                }
                cell.id = id
                if cells[id] != cell { changes.updateValue(cell, forKey: id) }
            }
        }
        return .success(changes)
    }
}
