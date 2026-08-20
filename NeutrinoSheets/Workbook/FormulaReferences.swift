import Foundation

// MARK: - FormulaReferences

/// Relative-reference rewriting, ported from `encodeFormula` / `decodeFormula` in
/// `web/apps/web/src/app/(apps)/sheets/editor/utils.ts`.
///
/// Copying `=A1+B1` from `C1` to `C2` has to produce `=A2+B2`, and `=$A$1` has to stay `=$A$1`. The
/// web app does that by *encoding* a formula against the cell it was copied from — every reference
/// becomes a signed delta, or the original letters when it was written absolute — and decoding it
/// against the cell it lands in. Both halves are reproduced here rather than reinvented, because a
/// spreadsheet copied on a phone and reopened in the browser has to hold the same formulas.
///
/// The encoding, for a reference in a cell at (row 2, column 3):
///
/// | written | encoded      |
/// |---------|--------------|
/// | `$A$1`  | `[$A][$1]`   |
/// | `A$1`   | `[-2][$1]`   |
/// | `$A1`   | `[$A][-1]`   |
/// | `A1`    | `[-2][-1]`   |
///
/// Cross-sheet prefixes (`Beta!`, `'Net Worth'!`) are pulled out before encoding and put back
/// afterwards: a bare sheet name is letters and digits, and would otherwise be mistaken for a
/// reference and rewritten into nonsense.
enum FormulaReferences {

    // MARK: - Public

    /// Whether text is a formula — the one place the `=` test is written.
    static func isFormula(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    /// Encodes every reference in `raw` relative to the cell holding it. Non-formulas pass through.
    static func encode(_ raw: String, at address: CellAddress) -> String {
        guard raw.hasPrefix("=") else { return raw }

        var prefixes: [String] = []
        let protected = rewrite(raw, with: sheetPrefixPattern) { match, text in
            prefixes.append(text.substring(with: match.range))
            // A placeholder made only of digits and NULs, so the reference pattern below cannot
            // match inside it.
            return "\u{0}\(prefixes.count - 1)\u{0}"
        }

        let encoded = rewrite(protected, with: referencePattern) { match, text in
            let dollarColumn = text.substring(with: match.range(at: 1))
            let letters = text.substring(with: match.range(at: 2)).uppercased()
            let dollarRow = text.substring(with: match.range(at: 3))
            let digits = text.substring(with: match.range(at: 4))

            let columnToken: String
            if dollarColumn.isEmpty {
                let column = CellAddress.columnIndex(fromLetters: letters) ?? 0
                columnToken = "[\(column - address.column)]"
            } else {
                columnToken = "[$\(letters)]"
            }

            let rowToken: String
            if dollarRow.isEmpty {
                rowToken = "[\((Int(digits) ?? 0) - address.row)]"
            } else {
                rowToken = "[$\(digits)]"
            }
            return columnToken + rowToken
        }

        return rewrite(encoded, with: placeholderPattern) { match, text in
            let index = Int(text.substring(with: match.range(at: 1))) ?? 0
            return prefixes.indices.contains(index) ? prefixes[index] : ""
        }
    }

    /// Decodes an encoded formula against the cell it is landing in. Non-formulas pass through.
    ///
    /// A reference that would shift off the top or left edge becomes `#REF!`, exactly as the web
    /// app writes it — silently clamping to row 1 would produce a formula that reads the wrong cell
    /// and looks fine doing it.
    static func decode(_ encoded: String, at address: CellAddress) -> String {
        guard encoded.hasPrefix("=") else { return encoded }
        return rewrite(encoded, with: tokenPattern) { match, text in
            let columnToken = text.substring(with: match.range(at: 1))
            let rowToken = text.substring(with: match.range(at: 2))

            let columnPart: String
            if columnToken.hasPrefix("$") {
                columnPart = columnToken
            } else {
                let column = address.column + (Int(columnToken) ?? 0)
                guard column >= 1 else { return "#REF!" }
                columnPart = CellAddress.columnLetters(column)
            }

            let rowPart: String
            if rowToken.hasPrefix("$") {
                rowPart = rowToken
            } else {
                let row = address.row + (Int(rowToken) ?? 0)
                guard row >= 1 else { return "#REF!" }
                rowPart = String(row)
            }
            return columnPart + rowPart
        }
    }

    /// Moves a formula from one cell to another in one step — what a fill and a same-session paste
    /// both need.
    static func shift(_ raw: String, from source: CellAddress, to destination: CellAddress) -> String {
        guard raw.hasPrefix("=") else { return raw }
        return decode(encode(raw, at: source), at: destination)
    }

    // MARK: - Patterns

    private static let sheetPrefixPattern = regex("('[^']+'!|[A-Za-z_][A-Za-z0-9_]*!)")
    private static let referencePattern = regex("(\\$?)([A-Za-z]+)(\\$?)([0-9]+)")
    private static let tokenPattern = regex("\\[(\\$[A-Z]+|-?[0-9]+)\\]\\[(\\$[0-9]+|-?[0-9]+)\\]")
    private static let placeholderPattern = regex("\u{0}([0-9]+)\u{0}")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals fixed at compile time; a failure here is a typo in this file,
        // not something a caller can cause or recover from.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    // MARK: - Private

    /// `String.replacingOccurrences` with a closure, which `NSRegularExpression` does not offer.
    private static func rewrite(_ text: String, with pattern: NSRegularExpression,
                                using transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor,
                                                     length: match.range.location - cursor))
            result += transform(match, source)
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
}
