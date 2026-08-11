import Foundation

// MARK: - CellStyle

/// Per-cell presentation, mirroring `CellStyle` in
/// `web/apps/web/src/app/(apps)/sheets/editor/types.ts`.
///
/// Every property is optional and every one is omitted when nil, because the web app writes a
/// sparse object — a cell that is only bold stores `{"fontWeight":"bold"}`, not fourteen nulls.
/// Emitting nulls would inflate a large workbook by megabytes and change bytes the web app never
/// writes.
///
/// The string-valued enums are deliberately *not* Swift enums: an unrecognised value must survive a
/// round trip rather than fail to decode, and `fontSize` really is a string on the wire ("14px").
struct CellStyle: Codable, Hashable {

    // MARK: - Text

    var fontFamily: String?
    /// A CSS length as written by the web app, e.g. `"14px"`. See ``pointSize``.
    var fontSize: String?
    /// `"bold"` or `"normal"`.
    var fontWeight: String?
    /// `"italic"` or `"normal"`.
    var fontStyle: String?
    /// `"line-through"` or `"none"`.
    var textDecoration: String?
    /// A CSS colour, e.g. `"#1f2937"`.
    var color: String?
    var backgroundColor: String?

    // MARK: - Alignment

    /// `"left"`, `"center"` or `"right"`.
    var textAlign: String?
    /// `"top"`, `"middle"` or `"bottom"`.
    var verticalAlign: String?
    /// `"overflow"`, `"wrap"` or `"clip"`.
    var wrapMode: String?

    // MARK: - Borders

    /// `"none"`, `"thin"`, `"medium"` or `"thick"` — applied to all four sides.
    var borderStyle: String?
    var borderTop: String?
    var borderRight: String?
    var borderBottom: String?
    var borderLeft: String?

    // MARK: - Numbers

    /// `"number"`, `"currency"`, `"percent"`, `"date"`, `"time"` or `"datetime"`.
    var numberFormat: String?
    var decimalPlaces: Int?
    /// An Excel-style pattern (`"#,##0.00"`, `"dd mmm yyyy"`) that overrides ``numberFormat``.
    var customFormat: String?

    // MARK: - Computed

    var isBold: Bool { fontWeight == "bold" }
    var isItalic: Bool { fontStyle == "italic" }
    var isStrikethrough: Bool { textDecoration == "line-through" }

    /// ``fontSize`` as a point size, or nil when absent or unparseable.
    ///
    /// The web app stores CSS pixels and renders at a 1:1 CSS-pixel-to-point ratio, so the number
    /// carries across unchanged; only the `px` suffix has to come off.
    var pointSize: CGFloat? {
        guard let fontSize else { return nil }
        let digits = fontSize.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value > 0 else { return nil }
        return CGFloat(value)
    }

    /// The border weight on one side, falling back to ``borderStyle`` the way the web app's CSS
    /// does — a per-side value overrides the all-sides one.
    func border(_ side: BorderSide) -> String? {
        let specific: String?
        switch side {
        case .top:    specific = borderTop
        case .right:  specific = borderRight
        case .bottom: specific = borderBottom
        case .left:   specific = borderLeft
        }
        let value = specific ?? borderStyle
        return value == "none" ? nil : value
    }

    enum BorderSide: CaseIterable { case top, right, bottom, left }
}

// MARK: - SavedCell

/// One persisted cell, mirroring `SavedCell` in the web app's `types.ts`.
struct SavedCell: Codable, Hashable {

    /// The cell's A1 address. Redundant with the key it is stored under, but the web app writes it
    /// into the value too and round-tripping means writing it back.
    var id: String
    /// What the user typed: a literal, or a formula beginning `=`.
    var raw: String?
    /// The pre-computed display value.
    ///
    /// This is why a *viewer* can ship before the formula engine does (Epic 15): the web app
    /// evaluates every formula and stores the result here, so rendering a workbook correctly needs
    /// no evaluation at all. It is also why an iOS edit to a cell that other formulas depend on
    /// cannot recompute them yet — Phase 1 edits literals, and Epic 15 is what makes the rest safe.
    var value: String?
    var cellStyle: CellStyle?

    // MARK: - Merges

    /// Columns this cell spans. `> 1` makes it a merge anchor.
    var colSpan: Int?
    /// Rows this cell spans. `> 1` makes it a merge anchor.
    var rowSpan: Int?
    /// The anchor cell's id when this cell is merged into another, e.g. `"B2"`.
    var mergeAnchor: String?

    // MARK: - Init

    init(id: String, raw: String? = nil, value: String? = nil, cellStyle: CellStyle? = nil,
         colSpan: Int? = nil, rowSpan: Int? = nil, mergeAnchor: String? = nil) {
        self.id = id
        self.raw = raw
        self.value = value
        self.cellStyle = cellStyle
        self.colSpan = colSpan
        self.rowSpan = rowSpan
        self.mergeAnchor = mergeAnchor
    }

    // MARK: - Computed

    /// True when this cell is covered by another cell's merge and so draws nothing of its own.
    var isMergedAway: Bool { mergeAnchor != nil }

    /// True when the cell holds neither a raw entry nor a display value — the web app's
    /// `isPopulatedCell` test, used to decide whether a cell is worth keeping.
    var isEmpty: Bool {
        (raw ?? "").isEmpty && (value ?? "").isEmpty
            && cellStyle == nil && colSpan == nil && rowSpan == nil && mergeAnchor == nil
    }

    /// What the formula bar shows: the raw entry if there is one, otherwise the display value.
    var editableText: String { raw ?? value ?? "" }
}

// MARK: - SheetData

/// One tab of a workbook, mirroring `SheetData` in the web app's `types.ts`.
///
/// `charts`, `conditionalFormats`, `cfVariables` and `tables` are *not* modelled. They are carried
/// in ``unknownFields`` and written back byte-for-byte, because Phase 1 cannot render them and a
/// typed model this app never reads would only be a way to lose them. See ``UnknownFields``.
struct SheetData: Hashable {

    // MARK: - Properties

    /// The tab's name. Optional on the wire; the web app falls back to `Sheet <n>`.
    var name: String?
    /// The tab colour as a CSS colour string, or nil for the default. Explicit `null` on the wire
    /// is equivalent to absent.
    var color: String?
    /// Cells keyed by A1 address.
    var cells: [String: SavedCell]
    /// Pixel widths keyed by **stringified 0-based column index**.
    var colWidths: [String: Double]?
    /// Pixel heights keyed by **stringified 0-based row index**.
    var rowHeights: [String: Double]?

    /// Everything the web app writes that this app does not model — charts, conditional formats, CF
    /// variables, table regions, and anything a future web release adds.
    var unknownFields: UnknownFields

    // MARK: - Init

    init(name: String? = nil, color: String? = nil, cells: [String: SavedCell] = [:],
         colWidths: [String: Double]? = nil, rowHeights: [String: Double]? = nil,
         unknownFields: UnknownFields = UnknownFields()) {
        self.name = name
        self.color = color
        self.cells = cells
        self.colWidths = colWidths
        self.rowHeights = rowHeights
        self.unknownFields = unknownFields
    }

    // MARK: - Computed

    /// The width of a 0-based column index, or nil to use the default.
    func width(ofColumn index: Int) -> Double? { colWidths?[String(index)] }

    /// The height of a 0-based row index, or nil to use the default.
    func height(ofRow index: Int) -> Double? { rowHeights?[String(index)] }

    /// The bottom-right extent of the populated cells, 1-based, or nil when the tab is empty.
    ///
    /// Merges are included at their full span so a merge running past the last populated cell is
    /// not cut off.
    var usedBounds: (rows: Int, columns: Int)? {
        var maxRow = 0
        var maxColumn = 0
        for (key, cell) in cells {
            guard !cell.isEmpty, let address = CellAddress(key) else { continue }
            maxRow = max(maxRow, address.row + max(0, (cell.rowSpan ?? 1) - 1))
            maxColumn = max(maxColumn, address.column + max(0, (cell.colSpan ?? 1) - 1))
        }
        return maxRow > 0 && maxColumn > 0 ? (maxRow, maxColumn) : nil
    }
}

// MARK: - SheetData + Codable

extension SheetData: Codable {

    /// The keys this type owns. Anything else is preserved opaquely.
    static let knownKeys: Set<String> = ["name", "color", "cells", "colWidths", "rowHeights"]

    private enum CodingKeys: String, CodingKey {
        case name, color, cells, colWidths, rowHeights
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        // `color` is `string | null` on the wire; `decodeIfPresent` maps both an explicit null and
        // an absent key to nil, which is what the web app's `?? null` does.
        color = try container.decodeIfPresent(String.self, forKey: .color)
        cells = try container.decodeIfPresent([String: SavedCell].self, forKey: .cells) ?? [:]
        colWidths = try container.decodeIfPresent([String: Double].self, forKey: .colWidths)
        rowHeights = try container.decodeIfPresent([String: Double].self, forKey: .rowHeights)
        unknownFields = try UnknownFields(from: decoder, excluding: Self.knownKeys)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `encodeIfPresent` throughout, matching the web app's sparse output: it writes `colWidths`
        // only when the map is non-empty, and a workbook that gained `"colWidths":{}` on every
        // mobile save would differ from the same workbook saved on the web for no reason.
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encode(cells, forKey: .cells)
        try container.encodeIfPresent(colWidths?.isEmpty == true ? nil : colWidths, forKey: .colWidths)
        try container.encodeIfPresent(rowHeights?.isEmpty == true ? nil : rowHeights, forKey: .rowHeights)
        try unknownFields.encode(to: encoder, excluding: Self.knownKeys)
    }
}

// MARK: - SheetFile

/// A whole workbook: the `{"sheets":[…]}` document stored as `sheet.json`.
///
/// This is the contract with the web app, so both directions matter — see ``decode(from:)`` for the
/// three shapes a stored body can actually take.
struct SheetFile: Hashable {

    var sheets: [SheetData]

    /// Top-level keys this app does not model, preserved for the same reason as ``SheetData``'s.
    var unknownFields: UnknownFields

    init(sheets: [SheetData] = [], unknownFields: UnknownFields = UnknownFields()) {
        self.sheets = sheets
        self.unknownFields = unknownFields
    }

    /// An empty workbook with a single tab, matching what the web editor shows for a new file.
    static var empty: SheetFile {
        SheetFile(sheets: [SheetData(name: "Sheet1")])
    }
}

// MARK: - SheetFile + Codable

extension SheetFile: Codable {

    static let knownKeys: Set<String> = ["sheets"]

    private enum CodingKeys: String, CodingKey {
        case sheets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sheets = try container.decodeIfPresent([SheetData].self, forKey: .sheets) ?? []
        unknownFields = try UnknownFields(from: decoder, excluding: Self.knownKeys)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sheets, forKey: .sheets)
        try unknownFields.encode(to: encoder, excluding: Self.knownKeys)
    }
}

// MARK: - SheetFile + Codec

extension SheetFile {

    /// Decodes a stored workbook body, tolerating everything the server can hand back.
    ///
    /// A `sheet.json` blob is one of three things, and only the first is the shape this type
    /// describes:
    ///
    /// 1. `{"sheets":[…]}` — written by the web editor and by this app.
    /// 2. `[{"index":"0","name":"Sheet1","celldata":[],…}]` — a **FortuneSheet-shaped array**, which
    ///    is what `native_types::EMPTY_SHEET_CONTENT` seeds a brand-new file with. Every
    ///    spreadsheet is this until something saves it. A decoder that required shape 1 would fail
    ///    to open every newly created spreadsheet, which is the sort of bug that gets found by a
    ///    user rather than by a test.
    /// 3. Something else entirely — a truncated body, a file that was never a spreadsheet.
    ///
    /// Shapes 2 and 3 both decode to an empty workbook, matching the web editor's `file.sheets ?? []`
    /// and its `catch { /* empty sheet, start fresh */ }`. The seeded array's tab *name* is read
    /// when it is there, so a new file opens showing "Sheet1" rather than an unnamed tab.
    ///
    /// The seeded body is deliberately not converted cell-by-cell: `celldata` is always `[]` in the
    /// constant, and writing a FortuneSheet importer for a format the app otherwise never sees
    /// would be code with no second caller and no way to be sure it is right.
    static func decode(from data: Data) -> SheetFile {
        if let file = try? JSONDecoder().decode(SheetFile.self, from: data), !file.sheets.isEmpty {
            return file
        }
        if let seeded = decodeSeededDefault(from: data) {
            return seeded
        }
        return .empty
    }

    /// Reads the tab names out of the server's seeded FortuneSheet array. Returns nil for anything
    /// that is not that shape.
    private static func decodeSeededDefault(from data: Data) -> SheetFile? {
        guard let array = try? JSONDecoder().decode([JSONValue].self, from: data) else { return nil }
        let names = array.compactMap { $0.objectValue?["name"]?.stringValue }
        guard !names.isEmpty else { return .empty }
        return SheetFile(sheets: names.map { SheetData(name: $0) })
    }

    /// Encodes the workbook as the web app writes it.
    ///
    /// `.sortedKeys` is what makes a round trip byte-stable: `JSONEncoder` orders dictionary keys
    /// arbitrarily otherwise, so the same workbook saved twice would produce two different blobs,
    /// and the fixtures in `WorkbookCodecTests` could not assert anything.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
