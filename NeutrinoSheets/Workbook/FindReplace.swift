import Foundation

// MARK: - FindReplace

/// Epic 10 — "Find & replace".
///
/// A port of the web app's `FindReplaceDialog`: it searches the **raw** entry rather than the
/// display value, so `=SUM(A1:A9)` is findable as text and a currency cell is searched as the
/// `1250.5` that was typed rather than as the `£1,250.50` on screen.
///
/// One divergence, deliberate: matches come back in true row-major order, by row and then by
/// *column number*. The browser sorts by row and then by the id's text, which puts `AA1` before
/// `B1` — an ordering nobody asked for that only shows up past column Z. Search order is not part
/// of the file format, so getting it right here costs nothing.
enum FindReplace {

    // MARK: - Options

    struct Options: Equatable {
        var matchCase = false
        /// Match only when the whole entry equals the query, rather than containing it.
        var entireCell = false
    }

    // MARK: - Searching

    /// Every cell matching `query`, in reading order. Empty for an empty query.
    static func matches(in cells: [String: SavedCell], query: String,
                        options: Options) -> [CellAddress] {
        guard !query.isEmpty else { return [] }

        var found: [CellAddress] = []
        for (id, cell) in cells {
            guard let address = CellAddress(id) else { continue }
            guard matches(cell.raw ?? "", query: query, options: options) else { continue }
            found.append(address)
        }
        return found.sorted()
    }

    /// Whether one entry matches.
    static func matches(_ text: String, query: String, options: Options) -> Bool {
        guard !query.isEmpty else { return false }
        let comparison: String.CompareOptions = options.matchCase ? [] : [.caseInsensitive]
        return options.entireCell
            ? text.compare(query, options: comparison) == .orderedSame
            : text.range(of: query, options: comparison) != nil
    }

    // MARK: - Replacing

    /// `text` with the query replaced.
    ///
    /// - Parameter all: every occurrence within the cell, rather than just the first — which is
    ///   what separates "Replace" from "Replace all" for a cell holding the query twice.
    static func replacing(_ text: String, query: String, with replacement: String,
                          options: Options, all: Bool) -> String {
        guard !query.isEmpty else { return text }
        let comparison: String.CompareOptions = options.matchCase ? [] : [.caseInsensitive]

        var result = ""
        var remaining = Substring(text)
        while let range = remaining.range(of: query, options: comparison) {
            result += remaining[remaining.startIndex..<range.lowerBound]
            result += replacement
            remaining = remaining[range.upperBound...]
            if !all { break }
        }
        return result + remaining
    }

    // MARK: - Cells

    /// The cell a replacement produces, or nil when it would be left holding nothing.
    ///
    /// A **formula loses its stored result**, exactly as a pasted one does (Epic 8). There is no
    /// evaluator yet, so rewriting `=SUM(A1:A9)` into `=SUM(B1:B9)` while keeping the old total
    /// would put a number in a shared file that no longer follows from the formula beside it. The
    /// cell shows its own formula text here and recomputes the moment the workbook is opened on the
    /// web, which re-evaluates every formula on load.
    static func replaced(_ cell: SavedCell, query: String, with replacement: String,
                         options: Options, all: Bool) -> SavedCell? {
        var updated = cell
        let raw = replacing(cell.raw ?? "", query: query, with: replacement, options: options,
                            all: all)
        updated.raw = raw.isEmpty ? nil : raw
        updated.value = raw.isEmpty || FormulaReferences.isFormula(raw) ? nil : raw
        return updated.isEmpty ? nil : updated
    }
}
