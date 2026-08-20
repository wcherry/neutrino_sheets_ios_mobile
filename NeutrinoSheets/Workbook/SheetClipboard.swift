import Foundation
import UIKit

// MARK: - SheetClipboard

/// Epic 8 — "Cut / copy / paste including styles and relative-reference rewriting".
///
/// A copied block is stored twice on the pasteboard, for two different readers:
///
/// - as **rich JSON** under a private type, carrying every cell's raw entry, display value and
///   style, with formulas encoded relative to the cell they came from (``FormulaReferences``);
/// - as **tab-separated text**, which is what Numbers, Excel and Mail will accept.
///
/// That mirrors the web app's `useClipboard`, which writes its own MIME type alongside
/// `text/plain` for exactly the same reason. Pasting prefers the rich payload and falls back to the
/// text, so a block copied here keeps its formatting, and one copied from another app still lands.
struct SheetClipboard: Codable, Hashable {

    // MARK: - Entry

    /// One cell of the copied block, positioned relative to its top-left corner.
    struct Entry: Codable, Hashable {
        var relativeRow: Int
        var relativeColumn: Int
        /// The raw entry with formula references encoded — see ``FormulaReferences/encode(_:at:)``.
        var raw: String?
        var value: String?
        var cellStyle: CellStyle?
    }

    /// True when the block was cut. The source is not cleared until the paste lands, so a cut that
    /// is never pasted loses nothing.
    var isCut: Bool
    var rows: Int
    var columns: Int
    var entries: [Entry]

    // MARK: - Building

    /// Reads a block out of a sheet.
    init(range: CellRange, cells: [String: SavedCell], isCut: Bool) {
        self.isCut = isCut
        rows = range.rowCount
        columns = range.columnCount
        entries = range.addresses.map { address in
            let cell = cells[address.id]
            return Entry(
                relativeRow: address.row - range.start.row,
                relativeColumn: address.column - range.start.column,
                raw: cell?.raw.map { FormulaReferences.encode($0, at: address) },
                value: cell?.value,
                cellStyle: cell?.cellStyle
            )
        }
    }

    private init(isCut: Bool, rows: Int, columns: Int, entries: [Entry]) {
        self.isCut = isCut
        self.rows = rows
        self.columns = columns
        self.entries = entries
    }

    // MARK: - Pasting

    /// The cells a paste will actually cover.
    ///
    /// A selection whose sides are whole multiples of the block **tiles** it — that is what makes
    /// "copy one cell, select a column, paste" fill the column, and what lets a one-row header be
    /// stamped across a table. A selection that is not a multiple is not asking to be tiled, so the
    /// block lands at its own size from the top-left corner; half a tile at the far edge would be a
    /// mess nobody asked for.
    func target(at origin: CellAddress, into selection: CellRange) -> CellRange {
        let natural = CellRange(origin, origin.offset(columns: max(0, columns - 1),
                                                      rows: max(0, rows - 1)))
        guard rows > 0, columns > 0, selection.cellCount > 1,
              selection.rowCount % rows == 0, selection.columnCount % columns == 0 else {
            return natural
        }
        return selection
    }

    /// The cells this block writes when pasted with its top-left corner at `origin`.
    ///
    /// Formulas are decoded against wherever they land, and their stored value is dropped: with no
    /// evaluator until Epic 15, the source's result is not this cell's result. An absent value is
    /// recomputed the moment the workbook is opened on the web, which re-evaluates every formula on
    /// load; a stale one would be a wrong number sitting in a shared file.
    func changes(at origin: CellAddress, into selection: CellRange,
                 existing cells: [String: SavedCell]) -> CellChanges {
        guard rows > 0, columns > 0 else { return [:] }
        let target = self.target(at: origin, into: selection)

        var byPosition: [String: Entry] = [:]
        for entry in entries {
            byPosition["\(entry.relativeRow),\(entry.relativeColumn)"] = entry
        }

        var changes: CellChanges = [:]
        for address in target.addresses {
            let row = (address.row - target.start.row) % rows
            let column = (address.column - target.start.column) % columns
            guard let entry = byPosition["\(row),\(column)"] else { continue }

            var cell = SavedCell(id: address.id)
            cell.cellStyle = entry.cellStyle
            // Merges belong to the destination grid, not to the values arriving on it.
            let existing = cells[address.id]
            cell.colSpan = existing?.colSpan
            cell.rowSpan = existing?.rowSpan
            cell.mergeAnchor = existing?.mergeAnchor

            if let raw = entry.raw, FormulaReferences.isFormula(raw) {
                cell.raw = FormulaReferences.decode(raw, at: address)
                cell.value = nil
            } else {
                cell.raw = entry.raw
                cell.value = entry.value ?? entry.raw
            }
            changes.updateValue(cell.isEmpty ? nil : cell, forKey: address.id)
        }
        return changes
    }

    // MARK: - Plain text

    /// The block as tab-separated rows, for pasting into another app.
    var tabSeparatedText: String {
        var grid = [[String]](repeating: [String](repeating: "", count: columns), count: rows)
        for entry in entries where entry.relativeRow < rows && entry.relativeColumn < columns {
            grid[entry.relativeRow][entry.relativeColumn] = entry.value ?? entry.raw ?? ""
        }
        return grid.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// Reads a block out of tab-separated text — anything copied in another app.
    ///
    /// The text is stored exactly as it arrived, including a leading `=`. Nothing is evaluated
    /// here, and nothing needs to be: a cell whose raw entry starts with `=` and whose value is
    /// absent renders as its own text on this device and is computed the moment the workbook is
    /// opened on the web. Inventing a display value for it is the one thing that would be wrong.
    static func fromTabSeparated(_ text: String) -> SheetClipboard? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // A trailing newline is normal and must not become an empty last row.
        let rows = lines.last?.isEmpty == true ? Array(lines.dropLast()) : lines
        guard !rows.isEmpty else { return nil }

        var entries: [Entry] = []
        var columns = 0
        for (rowIndex, line) in rows.enumerated() {
            let fields = line.components(separatedBy: "\t")
            columns = max(columns, fields.count)
            for (columnIndex, field) in fields.enumerated() {
                entries.append(Entry(relativeRow: rowIndex, relativeColumn: columnIndex,
                                     raw: field.isEmpty ? nil : field,
                                     value: field.isEmpty ? nil : field,
                                     cellStyle: nil))
            }
        }
        guard columns > 0 else { return nil }
        return SheetClipboard(isCut: false, rows: rows.count, columns: columns, entries: entries)
    }
}

// MARK: - PasteboardWriting

/// The pasteboard, behind a protocol so the editor's copy and paste can be tested without touching
/// the device's real one — `UIPasteboard.general` is global state shared with every other app on
/// the system, and a test suite that wrote to it would clear the user's clipboard.
protocol PasteboardWriting: AnyObject {
    /// Writes both representations as one item. They are set together because they describe the
    /// same copy: writing them separately lets a later text-only write leave a stale rich payload
    /// behind, and paste would then produce cells nobody copied.
    func write(payload: Data?, text: String)
    func readPayload() -> Data?
    func readText() -> String?
    /// Whether there is anything to paste.
    ///
    /// Separate from the readers on purpose: since iOS 16, *reading* another app's clipboard puts
    /// a system permission banner in front of the user. Greying out a menu item must not do that,
    /// so this asks only whether something is there.
    var hasContent: Bool { get }
}

// MARK: - SystemPasteboard

/// `UIPasteboard.general`, the real one.
final class SystemPasteboard: PasteboardWriting {

    /// The private type the rich payload travels under. Reverse-DNS and app-specific, so no other
    /// app can be handed a payload it would misread.
    static let payloadType = "com.neutrino.sheets.selection"

    private let pasteboard: UIPasteboard

    init(pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func write(payload: Data?, text: String) {
        var item: [String: Any] = [UTType.plainText: text]
        if let payload { item[Self.payloadType] = payload }
        pasteboard.setItems([item])
    }

    func readPayload() -> Data? {
        pasteboard.data(forPasteboardType: Self.payloadType)
    }

    func readText() -> String? {
        pasteboard.string
    }

    var hasContent: Bool {
        pasteboard.contains(pasteboardTypes: [Self.payloadType]) || pasteboard.hasStrings
    }

    /// `public.utf8-plain-text`, spelled out rather than imported: `UniformTypeIdentifiers` is
    /// iOS 14+ but its `UTType.utf8PlainText.identifier` is the same constant either way.
    private enum UTType {
        static let plainText = "public.utf8-plain-text"
    }
}
