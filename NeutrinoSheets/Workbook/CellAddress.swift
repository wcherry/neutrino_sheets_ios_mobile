import Foundation

// MARK: - CellAddress

/// An A1-style cell reference, ported from `numToAlpha` / `alphaToNum` / `parseCellId` in
/// `web/apps/web/src/app/(apps)/sheets/editor/utils.ts`.
///
/// Both components are **1-based**, matching the web app: `A1` is `(column: 1, row: 1)`. The
/// 0-based indices in `colWidths` / `rowHeights` are a different convention on the same file, which
/// is exactly why they get their own named accessors on ``SheetData`` rather than being mixed in
/// here — the two were confusable, so they are kept apart.
struct CellAddress: Hashable, Comparable, CustomStringConvertible {

    // MARK: - Limits

    /// The grid's bounds, matching `MAX_ROWS` / `MAX_COLS` in the web app's `constants.ts`.
    static let maxRow = 65536
    static let maxColumn = 65536

    // MARK: - Properties

    /// 1-based column. `A` is 1.
    let column: Int
    /// 1-based row.
    let row: Int

    // MARK: - Init

    init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    /// Parses `"A1"`, `"BC42"`. Returns nil for anything else — a lowercase reference, a range, an
    /// absolute `$A$1`, or a cell id from a file this app did not write.
    init?(_ id: String) {
        var letters = ""
        var digits = ""
        for character in id {
            if character.isUppercase && character.isLetter && digits.isEmpty {
                letters.append(character)
            } else if character.isNumber {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty,
              let row = Int(digits), row >= 1,
              let column = Self.columnIndex(fromLetters: letters) else { return nil }
        self.column = column
        self.row = row
    }

    // MARK: - Conversion

    /// `1 -> "A"`, `26 -> "Z"`, `27 -> "AA"`. Bijective base-26, as the web app writes it.
    static func columnLetters(_ index: Int) -> String {
        guard index >= 1 else { return "" }
        var remaining = index
        var letters = ""
        while remaining > 0 {
            remaining -= 1
            let scalar = UnicodeScalar(65 + UInt8(remaining % 26))
            letters = String(Character(scalar)) + letters
            remaining /= 26
        }
        return letters
    }

    /// `"A" -> 1`, `"AA" -> 27`. Returns nil for a non-alphabetic string or one long enough to
    /// overflow past the grid.
    static func columnIndex(fromLetters letters: String) -> Int? {
        guard !letters.isEmpty, letters.count <= 4 else { return nil }
        var index = 0
        for character in letters {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { return nil }
            index = index * 26 + Int(ascii - 64)
        }
        return index >= 1 && index <= maxColumn ? index : nil
    }

    // MARK: - Computed

    /// The A1 id this address is stored under.
    var id: String { "\(Self.columnLetters(column))\(row)" }

    var description: String { id }

    // MARK: - Navigation

    /// The address `columns` right and `rows` down, clamped to the grid.
    func offset(columns: Int = 0, rows: Int = 0) -> CellAddress {
        CellAddress(column: min(max(1, column + columns), Self.maxColumn),
                    row: min(max(1, row + rows), Self.maxRow))
    }

    // MARK: - Comparable

    /// Row-major order, which is the order a reader scans a grid in.
    static func < (lhs: CellAddress, rhs: CellAddress) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
    }
}

// MARK: - CellRange

/// A rectangular block of cells, as written `A1:C10`.
struct CellRange: Hashable {

    let start: CellAddress
    let end: CellAddress

    /// Normalises the corners so `start` is always the top-left, whichever way round they came in.
    init(_ a: CellAddress, _ b: CellAddress) {
        start = CellAddress(column: min(a.column, b.column), row: min(a.row, b.row))
        end = CellAddress(column: max(a.column, b.column), row: max(a.row, b.row))
    }

    var isSingleCell: Bool { start == end }

    /// `"A1"` for a single cell, `"A1:C10"` otherwise — the web app's `rangeAddress`.
    var address: String { isSingleCell ? start.id : "\(start.id):\(end.id)" }

    func contains(_ address: CellAddress) -> Bool {
        (start.column...end.column).contains(address.column)
            && (start.row...end.row).contains(address.row)
    }

    // MARK: - Extent

    var columns: ClosedRange<Int> { start.column...end.column }
    var rows: ClosedRange<Int> { start.row...end.row }
    var columnCount: Int { end.column - start.column + 1 }
    var rowCount: Int { end.row - start.row + 1 }
    var cellCount: Int { columnCount * rowCount }

    /// Every address in the block, row-major — the order a reader scans a grid in, and the order a
    /// paste has to write in so a formula referring to a cell above it sees the new value.
    var addresses: [CellAddress] {
        var result: [CellAddress] = []
        result.reserveCapacity(cellCount)
        for row in rows {
            for column in columns {
                result.append(CellAddress(column: column, row: row))
            }
        }
        return result
    }

    /// The smallest range containing both this one and `other`.
    func union(_ other: CellRange) -> CellRange {
        CellRange(CellAddress(column: min(start.column, other.start.column),
                              row: min(start.row, other.start.row)),
                  CellAddress(column: max(end.column, other.end.column),
                              row: max(end.row, other.end.row)))
    }
}

// MARK: - SheetSelection

/// What is selected on the active tab: a rectangle, plus which of its cells is *active*.
///
/// The two are kept in one value rather than as two published properties because they are only ever
/// meaningful together — an anchor without an active cell describes nothing, and a pair that drifts
/// apart is the classic way a range selection ends up highlighting one block while editing another.
///
/// - `anchor` is the corner a drag started from; it does not move while the drag runs.
/// - `active` is the corner under the finger, and is the cell the formula bar edits.
struct SheetSelection: Hashable {

    var anchor: CellAddress
    var active: CellAddress

    init(_ address: CellAddress) {
        anchor = address
        active = address
    }

    init(anchor: CellAddress, active: CellAddress) {
        self.anchor = anchor
        self.active = active
    }

    /// The normalised rectangle the two corners describe.
    var range: CellRange { CellRange(anchor, active) }

    var isSingleCell: Bool { anchor == active }

    /// What the formula bar's reference box shows: `A1`, or `A1:C10` for a block.
    var address: String { range.address }

    /// Moves the whole selection to one cell, collapsing any range.
    static func single(_ address: CellAddress) -> SheetSelection { SheetSelection(address) }
}
