import Foundation

// MARK: - ColumnFilters

/// Epic 10 — "Per-column filters".
///
/// A set of allowed values per column; a row whose cell in a filtered column holds anything else is
/// hidden. This is the web app's model exactly (`columnFilters: Map<number, Set<string>>`), down to
/// filtering on the **raw** entry rather than the formatted display value — the filter list shows
/// what was typed, and a filter that matched `£1,250.50` while the list offered `1250.5` would be
/// unusable.
///
/// Deliberately **not persisted**. The web app keeps filters in React state and writes nothing to
/// `sheet.json`; there is no field in the format for them. Inventing one here would put a key in a
/// shared file that the browser does not read and a later web release might claim for something
/// else. A filter is a way of looking at a workbook, not part of it.
struct ColumnFilters: Equatable {

    // MARK: - Storage

    /// Allowed values keyed by **1-based** column. A column with no entry is unfiltered.
    private(set) var allowed: [Int: Set<String>] = [:]

    var isEmpty: Bool { allowed.isEmpty }

    /// The filtered columns, left to right, for the status bar and the "clear all" affordance.
    var columns: [Int] { allowed.keys.sorted() }

    // MARK: - Editing

    func isFiltered(column: Int) -> Bool { allowed[column] != nil }

    /// Sets or clears one column's filter. Passing nil clears it.
    mutating func set(_ values: Set<String>?, forColumn column: Int) {
        allowed[column] = values
    }

    mutating func removeAll() { allowed.removeAll() }

    // MARK: - Applying

    /// The 1-based rows hidden by the active filters.
    ///
    /// - Parameter rows: how far down to test. The caller passes the tab's used extent: testing to
    ///   the format's 65,536-row maximum would walk a quarter of a million dictionary lookups per
    ///   filtered column to hide rows that hold nothing and are already indistinguishable from the
    ///   empty grid below them.
    func hiddenRows(in cells: [String: SavedCell], rows: Int) -> Set<Int> {
        guard !allowed.isEmpty, rows > 0 else { return [] }
        var hidden = Set<Int>()
        for row in 1...rows {
            for (column, values) in allowed {
                let raw = cells[CellAddress(column: column, row: row).id]?.raw ?? ""
                if !values.contains(raw) {
                    hidden.insert(row)
                    break
                }
            }
        }
        return hidden
    }

    // MARK: - Choices

    /// The distinct values in a column, in the order the filter list shows them.
    ///
    /// Blank is always offered — it is how a user hides the empty rows under their data, which is
    /// the single most common thing anyone filters for — and it always sorts last, matching both
    /// the web app's list and ``SortEngine``.
    static func values(inColumn column: Int, cells: [String: SavedCell], rows: Int) -> [String] {
        var values: Set<String> = [""]
        if rows > 0 {
            for row in 1...rows {
                values.insert(cells[CellAddress(column: column, row: row).id]?.raw ?? "")
            }
        }
        return values.sorted { SortEngine.compare($0, $1, ascending: true) == .orderedAscending }
    }
}
