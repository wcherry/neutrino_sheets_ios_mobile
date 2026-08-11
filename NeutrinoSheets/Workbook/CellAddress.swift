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
///
/// Phase 1 uses this for the address label and for merge bookkeeping; range *selection* is Epic 8.
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
}
