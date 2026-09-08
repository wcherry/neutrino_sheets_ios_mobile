import Foundation
import NeutrinoOOXML

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
/// `charts`, `conditionalFormats` and `cfVariables` are *not* modelled. They are carried in
/// ``unknownFields`` and written back byte-for-byte, because this app cannot render them and a
/// typed model it never reads would only be a way to lose them. See ``UnknownFields``.
///
/// `tables` was preserved the same way until Epic 9, which applies table styles and so has to be
/// able to *write* a region rather than only carry one. Claiming a preserved key is the one case
/// ``UnknownFields`` is designed to survive: the typed value wins, and it is the right winner
/// because it is the one the user just edited.
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
    /// Epic 9 — the ranges a table style has been applied to. See ``TableRegion``.
    var tables: [TableRegion]?

    /// Everything the web app writes that this app does not model — charts, conditional formats, CF
    /// variables, and anything a future web release adds.
    var unknownFields: UnknownFields

    // MARK: - Init

    init(name: String? = nil, color: String? = nil, cells: [String: SavedCell] = [:],
         colWidths: [String: Double]? = nil, rowHeights: [String: Double]? = nil,
         tables: [TableRegion]? = nil,
         unknownFields: UnknownFields = UnknownFields()) {
        self.name = name
        self.color = color
        self.cells = cells
        self.colWidths = colWidths
        self.rowHeights = rowHeights
        self.tables = tables
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
    static let knownKeys: Set<String> = ["name", "color", "cells", "colWidths", "rowHeights",
                                         "tables"]

    private enum CodingKeys: String, CodingKey {
        case name, color, cells, colWidths, rowHeights, tables
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
        // A `tables` array this app cannot read must not stop the workbook opening, and must not be
        // thrown away either: it falls back to the opaque path, so it is written out again exactly
        // as it arrived. Anything else would be a save that loses a range's table identity without
        // failing anywhere.
        tables = try? container.decodeIfPresent([TableRegion].self, forKey: .tables)
        unknownFields = try UnknownFields(from: decoder,
                                          excluding: tables == nil ? Self.knownKeys.subtracting(["tables"])
                                                                   : Self.knownKeys)
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
        try container.encodeIfPresent(tables?.isEmpty == true ? nil : tables, forKey: .tables)
        // `tables` is excluded from the opaque pass only when this app holds a typed value for it.
        // When it does not — an array in a shape a later web release invented — the preserved copy
        // is what gets written, and dropping it here would be the very loss it was kept against.
        try unknownFields.encode(to: encoder,
                                 excluding: tables == nil ? Self.knownKeys.subtracting(["tables"])
                                                          : Self.knownKeys)
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

    /// Decodes a stored workbook body — the bytes of a real `.xlsx`.
    ///
    /// A spreadsheet *is* an Excel workbook (issue #127): `XlsxCodec` reads the worksheet parts, or
    /// the `neutrino/model.json` part when the file predates the web's OOXML writer and still
    /// carries a trustworthy one. Either way what comes back is the same `{"sheets":[…]}` envelope
    /// this type has always decoded, which is why charts and conditional formats keep riding through
    /// ``UnknownFields`` untouched.
    ///
    /// A body that is not a package at all decodes to an empty workbook rather than throwing. That
    /// covers the one case that legitimately produces one: a spreadsheet created moments ago, whose
    /// Drive row exists with no content because an `.xlsx` is a zip the server has no business
    /// building. The editor opens it blank and its first save writes a real, sealed package.
    static func decode(from data: Data) -> SheetFile {
        guard !data.isEmpty, let json = try? XlsxCodec.decodeToJSON(data),
              let file = try? JSONDecoder().decode(SheetFile.self, from: json),
              !file.sheets.isEmpty else {
            return .empty
        }
        return file
    }

    /// Encodes the workbook as the `.xlsx` bytes to store.
    ///
    /// - Parameter previous: the package this one replaces. Its parts that neither implementation
    ///   understands — pivot tables, images, charts another tool wrote — are carried into the
    ///   result, so saving from a phone is not what strips a workbook that has been through Excel.
    func encoded(keeping previous: Data? = nil) throws -> Data {
        try XlsxCodec.encodeJSON(encodedJSON(), keeping: previous)
    }

    /// The `{"sheets":[…]}` envelope itself, which is what the codec speaks and what the round-trip
    /// tests compare.
    ///
    /// `.sortedKeys` is what makes it byte-stable: `JSONEncoder` orders dictionary keys arbitrarily
    /// otherwise, so the same workbook would encode two different ways.
    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
