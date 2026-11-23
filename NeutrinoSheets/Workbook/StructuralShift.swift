import Foundation

// MARK: - StructuralAxis

/// Which way a structural edit runs. `row` inserts and deletes rows; `column` does the same to
/// columns.
enum StructuralAxis {
    case row
    case column
}

// MARK: - StructuralOperation

enum StructuralOperation {
    case insert
    case delete
}

// MARK: - StructuralShift

/// Epic 10 — "Insert / delete rows and columns, with reference shifting matching
/// `structuralShift.ts`".
///
/// A port of `editor/structuralShift.ts`, kept pure so the rules can be tested without a workbook,
/// a selection or a view. The conventions are the web app's and are easy to get wrong, so they are
/// spelled out here:
///
/// - `index` is **1-based**, in the same numbering as a cell id: column `B` is 2, row 3 is 3.
///   Inserting at `index` pushes everything at or after it along; deleting at `index` drops that
///   coordinate and pulls everything after it back.
/// - `colWidths` / `rowHeights` are keyed by a **stringified 0-based** index. The conversion happens
///   in ``shift(sizes:operation:index:)`` and nowhere else.
/// - A merge anchor only grows or shrinks when the edit lands *strictly inside* its span. An anchor
///   the edit sits on top of, or past, rides along with the ordinary per-cell shift.
///
/// Three things the web app also does and this does too, because a workbook is shared between them:
/// surviving ``TableRegion``s are re-banded against their new bounds — otherwise a row inserted into
/// a table leaves an unstyled stripe — conditional-format ranges are shifted with the cells they
/// describe, and **formula references move with the cells they name** (``shiftFormula(_:axis:operation:index:target:formulaOnTarget:)``),
/// including references on other tabs that name this one. Charts are deliberately left alone; `computeStructuralShift` does not touch them
/// either, and inventing a rule here would put this app and the browser in disagreement.
enum StructuralShift {

    // MARK: - Cell ids

    /// The id a cell moves to, or nil when the edit deletes it.
    ///
    /// An id this app cannot parse is returned unchanged rather than dropped — a workbook written by
    /// a future release could hold keys in a shape ``CellAddress`` does not recognise, and losing
    /// them silently is worse than leaving them where they are.
    static func shiftedID(_ id: String, axis: StructuralAxis, operation: StructuralOperation,
                          index: Int) -> String? {
        guard let address = CellAddress(id) else { return id }
        let coordinate = axis == .row ? address.row : address.column

        var moved = coordinate
        switch operation {
        case .insert:
            if coordinate >= index { moved = coordinate + 1 }
        case .delete:
            if coordinate == index { return nil }
            if coordinate > index { moved = coordinate - 1 }
        }

        return axis == .row
            ? CellAddress(column: address.column, row: moved).id
            : CellAddress(column: moved, row: address.row).id
    }

    // MARK: - Cells

    /// Every cell moved to its new id, with merge spans and `mergeAnchor` pointers repaired.
    ///
    /// Three passes, in the order the web app runs them, because each depends on the last:
    ///
    /// 1. Work out which anchors the edit falls *inside*, in the original coordinates — once the
    ///    cells have moved there is no way to ask that question any more.
    /// 2. Move every cell, applying the span override to the anchors identified in pass 1.
    /// 3. Repoint each covered cell's `mergeAnchor`, and drop the pointer entirely when the anchor
    ///    it named has stopped being a merge — a cell claiming an anchor that no longer spans it
    ///    would draw nothing and be uneditable.
    static func shift(cells: [String: SavedCell], axis: StructuralAxis,
                      operation: StructuralOperation, index: Int) -> [String: SavedCell] {

        /// The new id and new span of one anchor the edit lands inside.
        struct AnchorInfo {
            let newID: String?
            let newSpan: Int?
        }

        let span: (SavedCell) -> Int? = { axis == .row ? $0.rowSpan : $0.colSpan }
        let otherSpan: (SavedCell) -> Int? = { axis == .row ? $0.colSpan : $0.rowSpan }

        // Pass 0.
        var anchors: [String: AnchorInfo] = [:]
        for (id, cell) in cells {
            guard let current = span(cell), current > 1, let address = CellAddress(id) else { continue }
            let start = axis == .row ? address.row : address.column
            let end = start + current - 1
            let strictlyInside = start < index && index <= end

            var newSpan: Int? = current
            if strictlyInside {
                newSpan = operation == .insert ? current + 1 : current - 1
                if let value = newSpan, value <= 1 { newSpan = nil }
            }
            anchors[id] = AnchorInfo(newID: shiftedID(id, axis: axis, operation: operation,
                                                      index: index),
                                     newSpan: newSpan)
        }

        // Pass 1. The anchor's own id is unaffected by the special case: `strictlyInside` implies
        // its start is before `index`, which the generic shift already leaves alone either way.
        var shifted: [String: SavedCell] = [:]
        shifted.reserveCapacity(cells.count)
        for (id, cell) in cells {
            guard let newID = shiftedID(id, axis: axis, operation: operation, index: index) else {
                continue
            }
            var moved = cell
            moved.id = newID
            if let info = anchors[id] {
                if axis == .row { moved.rowSpan = info.newSpan } else { moved.colSpan = info.newSpan }
            }
            shifted[newID] = moved
        }

        // Pass 2.
        var result: [String: SavedCell] = [:]
        result.reserveCapacity(shifted.count)
        for (newID, cell) in shifted {
            guard let oldAnchorID = cell.mergeAnchor else {
                result[newID] = cell
                continue
            }

            let newAnchorID: String?
            let anchorIsStillAMerge: Bool
            if let info = anchors[oldAnchorID] {
                newAnchorID = info.newID
                let other = cells[oldAnchorID].flatMap(otherSpan) ?? 1
                anchorIsStillAMerge = (info.newSpan ?? 1) > 1 || other > 1
            } else {
                newAnchorID = shiftedID(oldAnchorID, axis: axis, operation: operation, index: index)
                anchorIsStillAMerge = newAnchorID != nil
            }

            var repaired = cell
            repaired.mergeAnchor = anchorIsStillAMerge ? newAnchorID : nil
            result[newID] = repaired
        }

        return result
    }

    // MARK: - Rectangles

    /// A range moved by the edit, or nil when the edit consumed the last of it.
    ///
    /// Used for both table regions and conditional-format ranges: an insert inside a range stretches
    /// it, an insert before it moves it whole, and a delete does the inverse.
    static func shift(range: CellRange, axis: StructuralAxis, operation: StructuralOperation,
                      index: Int) -> CellRange? {
        var low = axis == .row ? range.start.row : range.start.column
        var high = axis == .row ? range.end.row : range.end.column

        switch operation {
        case .insert:
            if index <= low {
                low += 1
                high += 1
            } else if index <= high {
                high += 1
            }
        case .delete:
            if index < low {
                low -= 1
                high -= 1
            } else if index <= high {
                high -= 1
                if high < low { return nil }
            }
        }

        return axis == .row
            ? CellRange(CellAddress(column: range.start.column, row: low),
                        CellAddress(column: range.end.column, row: high))
            : CellRange(CellAddress(column: low, row: range.start.row),
                        CellAddress(column: high, row: range.end.row))
    }

    // MARK: - Sizes

    /// `colWidths` / `rowHeights` moved by the edit.
    ///
    /// - Parameter sizes: keyed by a **stringified 0-based** index, which is how the workbook stores
    ///   them; `index` is 1-based like everything else here, and is converted internally.
    static func shift(sizes: [String: Double], operation: StructuralOperation,
                      index: Int) -> [String: Double] {
        let zeroBased = index - 1
        var result: [String: Double] = [:]
        result.reserveCapacity(sizes.count)
        for (key, value) in sizes {
            // A key that is not a number is not one of ours; carried across untouched rather than
            // dropped, for the same reason an unparseable cell id is.
            guard let numeric = Int(key) else {
                result[key] = value
                continue
            }
            switch operation {
            case .insert:
                result[String(numeric >= zeroBased ? numeric + 1 : numeric)] = value
            case .delete:
                if numeric == zeroBased { continue }
                result[String(numeric > zeroBased ? numeric - 1 : numeric)] = value
            }
        }
        return result
    }

    // MARK: - Conditional formats

    /// Conditional-format ranges shifted in place inside the preserved JSON.
    ///
    /// This app does not model conditional formats — Epic 16 does — so they ride in
    /// ``UnknownFields`` and are written back byte-for-byte. That is right for every edit except
    /// this one: a rule whose `range` still says `A2:A9` after a row was inserted above it now
    /// colours the wrong cells, and the user would see it on the web rather than here. So the one
    /// key that means something is rewritten and everything else about the rule is left exactly as
    /// it arrived.
    ///
    /// Anything that is not the shape the web app writes — not an array, an entry with no `range`,
    /// a range that will not parse — is passed through untouched. A rule this app cannot read is
    /// still a rule somebody made.
    static func shiftConditionalFormats(_ value: JSONValue, axis: StructuralAxis,
                                        operation: StructuralOperation, index: Int) -> JSONValue {
        guard let rules = value.arrayValue else { return value }

        var shifted: [JSONValue] = []
        shifted.reserveCapacity(rules.count)
        for rule in rules {
            guard var fields = rule.objectValue,
                  let text = fields["range"]?.stringValue,
                  let range = parseRange(text) else {
                shifted.append(rule)
                continue
            }
            guard let moved = shift(range: range, axis: axis, operation: operation, index: index)
            else { continue }
            fields["range"] = .string(moved.address)
            // A formula rule's own references move too, as the web's `shiftCFRules` does.
            if var spec = fields["rule"]?.objectValue, spec["kind"]?.stringValue == "formula",
               let formula = spec["formula"]?.stringValue {
                spec["formula"] = .string(shiftFormula(formula, axis: axis, operation: operation, index: index))
                fields["rule"] = .object(spec)
            }
            shifted.append(.object(fields))
        }
        return .array(shifted)
    }

    /// `"A1"` or `"A1:C10"` as a range. Nil for anything else — an absolute reference, a named
    /// range, a cross-sheet one.
    static func parseRange(_ text: String) -> CellRange? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let address = CellAddress(String(parts[0])) else { return nil }
            return CellRange(address, address)
        case 2:
            guard let start = CellAddress(String(parts[0])),
                  let end = CellAddress(String(parts[1])) else { return nil }
            return CellRange(start, end)
        default:
            return nil
        }
    }

    // MARK: - Formulas

    /// A string literal, which is skipped, or a reference: an optional sheet prefix, then a cell or
    /// range. The lookarounds keep names that merely contain a reference (`LOG10(`, `Q1_total`) from
    /// matching. The web's `FORMULA_REFERENCE`, character for character.
    private static let formulaReference = try! NSRegularExpression(
        pattern: #""[^"]*"|(?<![A-Za-z0-9_$.'])(?:('[^']+'|[A-Za-z_][A-Za-z0-9_]*)!)?(\$?)([A-Za-z]+)(\$?)(\d+)(?::(\$?)([A-Za-z]+)(\$?)(\d+))?(?![A-Za-z0-9_(!])"#)

    /// The web's `shiftFormula`: a reference moves with its cell, a range grows or shrinks around the
    /// edit, and a reference to a deleted cell becomes `#REF!`. `$` references move too — `$` pins a
    /// reference against being copied, not against the sheet changing under it. A reference with no
    /// sheet prefix belongs to the formula's own sheet, so it moves only when `formulaOnTarget`; a
    /// prefixed one moves when it names `target` (case-insensitively).
    static func shiftFormula(_ formula: String, axis: StructuralAxis, operation: StructuralOperation,
                             index: Int, target: String? = nil, formulaOnTarget: Bool = true) -> String {
        let ns = formula as NSString
        let wanted = target?.lowercased()
        var result = ""
        var cursor = 0
        for match in formulaReference.matches(in: formula, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let whole = ns.substring(with: match.range)
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let col1 = group(3), let row1Text = group(5), let row1 = Int(row1Text) else {
                result += whole // a string literal
                continue
            }
            let prefix = group(1)
            let onTarget: Bool
            if let prefix {
                var name = prefix
                if name.hasPrefix("'") { name.removeFirst() }
                if name.hasSuffix("'") { name.removeLast() }
                onTarget = name.lowercased() == wanted
            } else {
                onTarget = formulaOnTarget
            }
            guard onTarget,
                  let c1 = CellAddress.columnIndex(fromLetters: col1.uppercased()) else {
                result += whole
                continue
            }
            let col2 = group(7)
            let c2 = col2.flatMap { CellAddress.columnIndex(fromLetters: $0.uppercased()) } ?? c1
            let r2 = group(9).flatMap(Int.init) ?? row1
            if col2 != nil, CellAddress.columnIndex(fromLetters: col2!.uppercased()) == nil {
                result += whole
                continue
            }
            let bounds = CellRange(CellAddress(column: min(c1, c2), row: min(row1, r2)),
                                   CellAddress(column: max(c1, c2), row: max(row1, r2)))
            guard let moved = shift(range: bounds, axis: axis, operation: operation, index: index) else {
                result += "#REF!"
                continue
            }
            if moved == bounds {
                result += whole
                continue
            }
            // A range may be written back to front (B3:A1); it stays that way round.
            let d = { (i: Int) in group(i) ?? "" }
            let startColumn = c1 <= c2 ? moved.start.column : moved.end.column
            let startRow = row1 <= r2 ? moved.start.row : moved.end.row
            var text = (prefix.map { "\($0)!" } ?? "") + d(2) + CellAddress.columnLetters(startColumn) + d(4) + String(startRow)
            if col2 != nil {
                let endColumn = c1 <= c2 ? moved.end.column : moved.start.column
                let endRow = row1 <= r2 ? moved.end.row : moved.start.row
                text += ":" + d(6) + CellAddress.columnLetters(endColumn) + d(8) + String(endRow)
            }
            result += text
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// A formula cell rewritten by an edit keeps its cached value — its references still name the
    /// same cells — unless the edit deleted one of them, when it shows `#REF!` as the web's
    /// recalculation would.
    private static func shiftingFormula(of cell: SavedCell, axis: StructuralAxis, operation: StructuralOperation,
                                        index: Int, target: String?, formulaOnTarget: Bool) -> SavedCell {
        guard let raw = cell.raw, FormulaReferences.isFormula(raw) else { return cell }
        let moved = shiftFormula(raw, axis: axis, operation: operation, index: index,
                                 target: target, formulaOnTarget: formulaOnTarget)
        guard moved != raw else { return cell }
        var updated = cell
        updated.raw = moved
        if moved.contains("#REF!"), !raw.contains("#REF!") { updated.value = "#REF!" }
        return updated
    }

    /// The same edit as another tab sees it: only references that name `target` move. Nil when
    /// nothing on the tab did.
    static func shiftReferences(in sheet: SheetData, toSheetNamed target: String, axis: StructuralAxis,
                                operation: StructuralOperation, index: Int) -> SheetData? {
        var changed = false
        var result = sheet
        for (id, cell) in sheet.cells {
            let updated = shiftingFormula(of: cell, axis: axis, operation: operation, index: index,
                                          target: target, formulaOnTarget: false)
            if updated != cell { result.cells[id] = updated; changed = true }
        }
        return changed ? result : nil
    }

    // MARK: - Whole sheet

    /// One structural edit applied to a whole tab — the orchestrator, matching
    /// `computeStructuralShift`.
    ///
    /// Table regions are the reason this is one function rather than four calls at the call site:
    /// a surviving region has to be re-banded against its *new* bounds, and that has to happen after
    /// the cells have moved and before anything else reads them. Skipping it is what leaves an
    /// unstyled row in the middle of a table.
    static func apply(to sheet: SheetData, axis: StructuralAxis, operation: StructuralOperation,
                      index: Int) -> SheetData {
        var result = sheet
        result.cells = shift(cells: sheet.cells, axis: axis, operation: operation, index: index)
            .mapValues { shiftingFormula(of: $0, axis: axis, operation: operation, index: index,
                                         target: sheet.name, formulaOnTarget: true) }

        var regions: [TableRegion] = []
        for region in sheet.tables ?? [] {
            guard region.isValid,
                  let moved = shift(range: region.range, axis: axis, operation: operation,
                                    index: index) else { continue }
            var shiftedRegion = region
            shiftedRegion.minR = moved.start.row
            shiftedRegion.maxR = moved.end.row
            shiftedRegion.minC = moved.start.column
            shiftedRegion.maxC = moved.end.column
            regions.append(shiftedRegion)

            guard let style = TableStyles.style(withID: region.styleId)?.regular else { continue }
            for (id, patch) in TableStyles.patches(for: style, in: moved) {
                var cell = result.cells[id] ?? SavedCell(id: id)
                cell.cellStyle = patch.applied(to: cell.cellStyle)
                result.cells[id] = cell
            }
        }
        result.tables = regions.isEmpty ? nil : regions

        if axis == .column, let widths = sheet.colWidths {
            result.colWidths = shift(sizes: widths, operation: operation, index: index)
        }
        if axis == .row, let heights = sheet.rowHeights {
            result.rowHeights = shift(sizes: heights, operation: operation, index: index)
        }
        if let formats = sheet.unknownFields["conditionalFormats"] {
            result.unknownFields["conditionalFormats"] =
                shiftConditionalFormats(formats, axis: axis, operation: operation, index: index)
        }

        return result
    }

    /// Several edits along one axis, chained so they land as a single change.
    ///
    /// The caller passes the indices in whatever order keeps them valid across the chain: repeated
    /// for an insert, so a block of rows goes in at one place, and **descending** for a delete, so
    /// removing one row never renumbers the ones still to go.
    static func apply(to sheet: SheetData, axis: StructuralAxis, operation: StructuralOperation,
                      indices: [Int]) -> SheetData {
        indices.reduce(sheet) { apply(to: $0, axis: axis, operation: operation, index: $1) }
    }
}
