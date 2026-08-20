import Foundation

// MARK: - CellChanges

/// A batch of cell writes, keyed by A1 address.
///
/// The value is `SavedCell?` and a `nil` means **remove the cell**, which is how an empty cell is
/// stored: the web app writes an absent key, not a key holding `""`. Every mutation in the editor
/// is expressed in this shape so undo can be recorded by simply reading the same keys back first.
///
/// Always write through ``updateValue(_:forKey:)`` rather than the subscript — `changes[id] = nil`
/// on a dictionary of optionals *removes the key* instead of recording a deletion, which is the
/// difference between "clear this cell" and "leave it alone".
typealias CellChanges = [String: SavedCell?]

// MARK: - FillEngine

/// Epic 8 — "Fill handle (drag to fill, series detection)".
///
/// Dragging the handle at the corner of a selection extends it. What "extends" means depends on
/// what is there: two numbers one apart continue counting, `Jan` and `Feb` continue through the
/// months, `Item 1` becomes `Item 2`, and anything the engine cannot read as a series simply
/// repeats. Excel's rules, near enough that a user does not have to learn new ones.
///
/// The single-cell cases are where spreadsheets differ from one another, so they are stated here:
/// a lone **number** repeats (Excel copies it rather than counting), a lone **date** advances by a
/// day, and a lone **`Item 1`** counts up. That asymmetry is Excel's, and matching it matters more
/// than being self-consistent.
enum FillEngine {

    // MARK: - Fill

    /// Extends the cells in `source` to cover `target`.
    ///
    /// `target` must contain `source` and grow along one axis only — the drag that produces it is
    /// constrained the same way, because a fill that grew in both directions at once would have no
    /// single series to continue.
    static func fill(source: CellRange, target: CellRange,
                     cells: [String: SavedCell]) -> CellChanges {
        let vertical = target.columns == source.columns && target.rows != source.rows
        let horizontal = target.rows == source.rows && target.columns != source.columns
        guard vertical != horizontal else { return [:] }

        var changes: CellChanges = [:]

        if vertical {
            for column in source.columns {
                let ascending = source.rows.map { CellAddress(column: column, row: $0) }
                if target.end.row > source.end.row {
                    let rows = (source.end.row + 1)...target.end.row
                    changes.merge(extend(from: ascending,
                                         to: rows.map { CellAddress(column: column, row: $0) },
                                         cells: cells)) { _, new in new }
                }
                if target.start.row < source.start.row {
                    let rows = (target.start.row...(source.start.row - 1)).reversed()
                    changes.merge(extend(from: ascending.reversed(),
                                         to: rows.map { CellAddress(column: column, row: $0) },
                                         cells: cells)) { _, new in new }
                }
            }
        } else {
            for row in source.rows {
                let ascending = source.columns.map { CellAddress(column: $0, row: row) }
                if target.end.column > source.end.column {
                    let columns = (source.end.column + 1)...target.end.column
                    changes.merge(extend(from: ascending,
                                         to: columns.map { CellAddress(column: $0, row: row) },
                                         cells: cells)) { _, new in new }
                }
                if target.start.column < source.start.column {
                    let columns = (target.start.column...(source.start.column - 1)).reversed()
                    changes.merge(extend(from: ascending,
                                         to: columns.map { CellAddress(column: $0, row: row) },
                                         cells: cells)) { _, new in new }
                }
            }
        }
        return changes
    }

    /// Continues one line of cells into the addresses beyond it.
    ///
    /// `sources` is in *fill order*: dragging upwards passes the line bottom-to-top, so the series
    /// is fitted the way it is being extended and a backward fill needs no special arithmetic.
    private static func extend(from sources: [CellAddress], to destinations: [CellAddress],
                               cells: [String: SavedCell]) -> CellChanges {
        guard !sources.isEmpty, !destinations.isEmpty else { return [:] }

        let sourceCells = sources.map { cells[$0.id] }
        let texts = sourceCells.map { $0?.editableText ?? "" }
        let series = series(for: texts)

        var changes: CellChanges = [:]
        for (offset, destination) in destinations.enumerated() {
            let index = offset % sources.count
            let template = sourceCells[index]
            let existing = cells[destination.id]

            guard let template, !template.isEmpty else {
                // Filling from a blank clears what it lands on; leaving the old value would make a
                // fill that shrinks a table silently keep its last rows.
                changes.updateValue(nil, forKey: destination.id)
                continue
            }

            var cell = SavedCell(id: destination.id)
            cell.cellStyle = template.cellStyle
            // A merge belongs to the grid, not to the values being filled over it, so the
            // destination keeps its own spans.
            cell.colSpan = existing?.colSpan
            cell.rowSpan = existing?.rowSpan
            cell.mergeAnchor = existing?.mergeAnchor

            if let raw = template.raw, FormulaReferences.isFormula(raw) {
                cell.raw = FormulaReferences.shift(raw, from: sources[index], to: destination)
                // `value` is deliberately dropped rather than carried across. There is no evaluator
                // until Epic 15, and the source's result is not this cell's result — storing it
                // would put a number in the file that the formula above it does not produce. An
                // absent value re-evaluates the moment the workbook is opened on the web, which
                // recomputes every formula on load (`evaluateSheetMap`).
                cell.value = nil
            } else {
                let text = text(of: series, at: sources.count + offset, source: texts, index: index)
                cell.raw = text.isEmpty ? nil : text
                cell.value = cell.raw
            }
            changes.updateValue(cell.isEmpty ? nil : cell, forKey: destination.id)
        }
        return changes
    }

    // MARK: - Series

    /// What a line of source cells looks like it is counting.
    enum Series: Equatable {
        /// Numbers on a straight line: `intercept + slope × position`.
        case linear(intercept: Double, slope: Double, decimals: Int)
        /// Text ending in digits, e.g. `Item 1`, `Q3`, `Run 007`.
        case numbered(prefix: String, intercept: Double, slope: Double, width: Int)
        /// Entries of a fixed cyclic list — the months and the days of the week.
        case names(list: NameList, start: Int, step: Int, casing: Casing)
        /// Dates a whole number of days apart.
        case dates(start: Double, step: Double, style: DateStyle)
        /// Nothing to continue — the source block repeats.
        case repeating
    }

    enum Casing: Equatable { case canonical, upper, lower }
    enum DateStyle: Equatable { case iso, american }

    /// Infers the series a line of text is following. Order matters: a plain number is tested
    /// before a date, so `2026` counts rather than being read as a year.
    static func series(for values: [String]) -> Series {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespaces) }
        guard trimmed.contains(where: { !$0.isEmpty }) else { return .repeating }
        return linearSeries(trimmed)
            ?? dateSeries(trimmed)
            ?? nameSeries(trimmed)
            ?? numberedSeries(trimmed)
            ?? .repeating
    }

    /// The text at a position along the series. `position` counts from the first source cell, so
    /// the first filled cell of an *n*-cell source is at position *n*.
    ///
    /// - Parameter index: which source cell this destination is tiled from, used by ``repeating``.
    static func text(of series: Series, at position: Int, source: [String], index: Int) -> String {
        switch series {
        case .linear(let intercept, let slope, let decimals):
            return number(intercept + slope * Double(position), decimals: decimals)

        case .numbered(let prefix, let intercept, let slope, let width):
            let value = Int((intercept + slope * Double(position)).rounded())
            let digits = String(abs(value))
            let padded = digits.count >= width ? digits
                : String(repeating: "0", count: width - digits.count) + digits
            return prefix + (value < 0 ? "-" : "") + padded

        case .names(let list, let start, let step, let casing):
            let entries = list.entries
            let raw = (start + step * position) % entries.count
            let name = entries[raw < 0 ? raw + entries.count : raw]
            switch casing {
            case .canonical: return name
            case .upper:     return name.uppercased()
            case .lower:     return name.lowercased()
            }

        case .dates(let start, let step, let style):
            let date = CellFormatter.date(fromExcelSerial: start + step * Double(position))
            return style.formatter.string(from: date)

        case .repeating:
            return source.indices.contains(index) ? source[index] : ""
        }
    }

    // MARK: - Detection

    private static func linearSeries(_ values: [String]) -> Series? {
        var numbers: [Double] = []
        var decimals = 0
        for value in values {
            guard isPlainNumber(value), let number = Double(value) else { return nil }
            numbers.append(number)
            if let dot = value.firstIndex(of: ".") {
                let places = value[value.index(after: dot)...].prefix { $0.isNumber }.count
                decimals = max(decimals, places)
            }
        }
        // A single number repeats rather than counts — Excel's behaviour, and the one users rely
        // on when they drag a constant down a column.
        let fit = self.fit(numbers)
        return .linear(intercept: fit.intercept, slope: fit.slope, decimals: decimals)
    }

    private static func dateSeries(_ values: [String]) -> Series? {
        var serials: [Double] = []
        var style: DateStyle?
        for value in values {
            guard let matched = DateStyle.detect(value),
                  let serial = CellFormatter.serial(fromDateString: value),
                  serial == serial.rounded() else { return nil }
            if let style, style != matched { return nil }
            style = matched
            serials.append(serial)
        }
        guard let style, let first = serials.first else { return nil }

        // A lone date advances by a day; the alternative — repeating it — is never what dragging a
        // date down a column is asking for.
        guard serials.count > 1 else { return .dates(start: first, step: 1, style: style) }
        let fit = self.fit(serials)
        guard fit.slope == fit.slope.rounded() else { return nil }
        return .dates(start: fit.intercept, step: fit.slope, style: style)
    }

    private static func nameSeries(_ values: [String]) -> Series? {
        for list in NameList.allCases {
            var indices: [Int] = []
            for value in values {
                guard let index = list.index(of: value) else { break }
                indices.append(index)
            }
            guard indices.count == values.count, let first = indices.first else { continue }

            let count = list.entries.count
            var step = 1
            if indices.count > 1 {
                let deltas = zip(indices, indices.dropFirst()).map { ($1 - $0 + count) % count }
                guard let delta = deltas.first, deltas.allSatisfy({ $0 == delta }) else { continue }
                // A wrap-around delta reads more naturally as a small negative step: Dec, Nov is
                // counting backwards, not forwards by eleven.
                step = delta > count / 2 ? delta - count : delta
            }
            let casing: Casing
            if values[0] == values[0].uppercased() && values[0] != values[0].lowercased() {
                casing = .upper
            } else if values[0] == values[0].lowercased() {
                casing = .lower
            } else {
                casing = .canonical
            }
            return .names(list: list, start: first, step: step, casing: casing)
        }
        return nil
    }

    private static func numberedSeries(_ values: [String]) -> Series? {
        var prefix: String?
        var numbers: [Double] = []
        var width = 0
        for value in values {
            let digits = value.reversed().prefix { $0.isNumber }.reversed()
            guard !digits.isEmpty else { return nil }
            let head = String(value.dropLast(digits.count))
            guard !head.isEmpty, let number = Double(String(digits)) else { return nil }
            if let prefix, prefix != head { return nil }
            prefix = head
            width = max(width, digits.first == "0" ? digits.count : 0)
            numbers.append(number)
        }
        guard let prefix else { return nil }
        // A single `Item 1` counts up. Unlike a bare number this is unambiguous — nobody drags a
        // labelled row down expecting nine copies of the same label.
        let fit = numbers.count > 1 ? self.fit(numbers)
            : (intercept: numbers[0], slope: 1.0)
        return .numbered(prefix: prefix, intercept: fit.intercept, slope: fit.slope, width: width)
    }

    // MARK: - Arithmetic

    /// Least-squares line through the values at positions `0..<count`.
    ///
    /// Fitting rather than differencing is what Excel does, and it means `1, 2, 4` extends to `5.5`
    /// instead of refusing: an evenly spaced run reduces to exactly its own step, and an uneven one
    /// still produces the trend the user drew.
    private static func fit(_ values: [Double]) -> (intercept: Double, slope: Double) {
        guard values.count > 1 else { return (values.first ?? 0, 0) }
        let n = Double(values.count)
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for (index, value) in values.enumerated() {
            let dx = Double(index) - meanX
            covariance += dx * (value - meanY)
            variance += dx * dx
        }
        let slope = variance == 0 ? 0 : covariance / variance
        return (meanY - slope * meanX, slope)
    }

    /// Whether the whole string is a number — `CellFormatter.parseNumber` is deliberately lenient
    /// about trailing junk, and a series must not read `3 apples` as a 3.
    private static func isPlainNumber(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var body = Substring(value)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, body.contains(where: \.isNumber) else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Formats a filled number back to text, keeping the source's precision.
    private static func number(_ value: Double, decimals: Int) -> String {
        // `-0` is what a descending series lands on at zero and it reads as a bug in a cell.
        let cleaned = value == 0 ? 0 : value
        return String(format: "%.\(decimals)f", cleaned)
    }

    // MARK: - Name lists

    /// The cyclic lists a fill can walk. Longest-first, so `January` is not matched as `Jan`.
    enum NameList: CaseIterable {
        case monthsLong, monthsShort, weekdaysLong, weekdaysShort

        var entries: [String] {
            switch self {
            case .monthsLong:
                return ["January", "February", "March", "April", "May", "June", "July",
                        "August", "September", "October", "November", "December"]
            case .monthsShort:
                return ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            case .weekdaysLong:
                return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            case .weekdaysShort:
                return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            }
        }

        func index(of value: String) -> Int? {
            let needle = value.lowercased()
            return entries.firstIndex { $0.lowercased() == needle }
        }
    }
}

// MARK: - FillEngine.DateStyle

extension FillEngine.DateStyle {

    /// Recognises a date-only string and which way round it is written. A value carrying a time is
    /// not matched: a fill that silently dropped the time would be worse than not filling.
    static func detect(_ value: String) -> Self? {
        let parts = value.split(separator: "-")
        if parts.count == 3, parts[0].count == 4,
           parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return .iso
        }
        let slashed = value.split(separator: "/")
        if slashed.count == 3, slashed.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return .american
        }
        return nil
    }

    /// Fixed-locale and UTC, matching how the workbook stores dates — a device in another region
    /// must not write dates a colleague's browser reads back as a different day.
    var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = self == .iso ? "yyyy-MM-dd" : "MM/dd/yyyy"
        return formatter
    }
}
