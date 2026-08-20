import Foundation

// MARK: - RangeSummary

/// Epic 8 — the "live sum / count / average status bar" under a range selection.
///
/// Deliberately not a formula evaluation: it reads the display values already in the file, which is
/// exactly what makes it safe before Epic 15. Nothing here is written back to the workbook, so a
/// wrong answer would be a wrong *readout* rather than a corrupted cell — and there is no wrong
/// answer to be had, because summing stored numbers needs no evaluator.
struct RangeSummary: Equatable {

    /// Cells holding anything at all, numeric or not — the count a spreadsheet's status bar shows.
    let count: Int
    /// Of those, the ones that read as numbers.
    let numericCount: Int
    let sum: Double

    /// Nil when nothing numeric was selected, rather than a zero that would look like a real mean.
    var average: Double? {
        numericCount > 0 ? sum / Double(numericCount) : nil
    }

    /// Whether there is anything worth putting on screen. A selection of empty cells has no
    /// summary, and showing "Sum 0" over blank cells is noise.
    var isEmpty: Bool { count == 0 }

    // MARK: - Building

    /// Summarises a block of a sheet.
    ///
    /// A merged-away cell is skipped: its value is drawn by the anchor, and counting both would
    /// double every merged entry in the selection.
    ///
    /// Walks whichever side is smaller — the range's addresses, or the sheet's populated cells.
    /// Selecting a whole column is one tap on a header, and 65,536 dictionary lookups to answer a
    /// status line about six numbers is not a trade worth making.
    init(range: CellRange, cells: [String: SavedCell]) {
        var count = 0
        var numericCount = 0
        var sum = 0.0

        func accumulate(_ cell: SavedCell) {
            guard !cell.isMergedAway else { return }
            let text = cell.value ?? cell.raw ?? ""
            guard !text.isEmpty else { return }
            count += 1
            if let number = CellFormatter.parseNumber(text) {
                numericCount += 1
                sum += number
            }
        }

        if range.cellCount <= cells.count {
            for address in range.addresses {
                guard let cell = cells[address.id] else { continue }
                accumulate(cell)
            }
        } else {
            for (id, cell) in cells {
                guard let address = CellAddress(id), range.contains(address) else { continue }
                accumulate(cell)
            }
        }

        self.count = count
        self.numericCount = numericCount
        self.sum = sum
    }

    // MARK: - Display

    /// The one-line readout, e.g. `Sum 1,234  ·  Avg 411.33  ·  Count 3`.
    ///
    /// Sum and average are dropped when nothing in the selection is a number, leaving the count —
    /// which is still the useful answer for a block of labels.
    var statusText: String {
        var parts: [String] = []
        if numericCount > 0 {
            parts.append("Sum \(Self.format(sum))")
            if let average { parts.append("Avg \(Self.format(average))") }
        }
        parts.append("Count \(count)")
        return parts.joined(separator: "  \u{00B7}  ")
    }

    /// Grouped, and at most two decimal places — a status bar is a glance, not a report.
    private static func format(_ value: Double) -> String {
        let decimals = value == value.rounded() ? 0 : 2
        return CellFormatter.decimal(value, decimals: decimals, grouping: true)
    }
}
