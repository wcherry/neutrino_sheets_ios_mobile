import Foundation

// MARK: - TableRegion

/// A range that has had a table style applied to it, mirroring `TableRegion` in the web app's
/// `editor/types.ts` and stored under a sheet's `tables` key.
///
/// The region is not what draws the table — the banding and the header colours are ordinary cell
/// styles, written once when the style is applied. What the region records is *that the range is a
/// table*, which is what lets the web app re-band it after a row is inserted in the middle. Epic 10
/// is where this app gains that behaviour; carrying the region correctly is what makes it possible,
/// and what stops a mobile save from making the web app forget.
///
/// Bounds are **1-based and inclusive**, the same convention as ``CellAddress``.
struct TableRegion: Hashable, Identifiable {

    var id: String
    /// A `TableStyle.id` from ``TableStyles``, e.g. `"blue-banded"`.
    var styleId: String
    var minR: Int
    var maxR: Int
    var minC: Int
    var maxC: Int

    /// Anything a later web release adds to a region, preserved for the same reason a sheet's
    /// unknown fields are — see ``UnknownFields``.
    var unknownFields: UnknownFields

    // MARK: - Init

    init(id: String, styleId: String, minR: Int, maxR: Int, minC: Int, maxC: Int,
         unknownFields: UnknownFields = UnknownFields()) {
        self.id = id
        self.styleId = styleId
        self.minR = minR
        self.maxR = maxR
        self.minC = minC
        self.maxC = maxC
        self.unknownFields = unknownFields
    }

    init(id: String, styleId: String, range: CellRange) {
        self.init(id: id, styleId: styleId,
                  minR: range.start.row, maxR: range.end.row,
                  minC: range.start.column, maxC: range.end.column)
    }

    /// An id in the shape the web app writes, `table-<something unique>`.
    static func makeID() -> String {
        "table-\(UUID().uuidString.lowercased())"
    }

    // MARK: - Geometry

    var range: CellRange {
        CellRange(CellAddress(column: minC, row: minR), CellAddress(column: maxC, row: maxR))
    }

    /// True when the bounds describe a real rectangle. A region with `maxR < minR` covers nothing
    /// and would never overlap anything, so it is not worth keeping.
    var isValid: Bool { minR <= maxR && minC <= maxC && minR >= 1 && minC >= 1 }

    /// The standard rectangle-overlap test, matching the web app's `regionsOverlap`.
    func overlaps(_ other: TableRegion) -> Bool {
        !(maxC < other.minC || other.maxC < minC || maxR < other.minR || other.maxR < minR)
    }

    func overlaps(_ range: CellRange) -> Bool {
        overlaps(TableRegion(id: "", styleId: "", range: range))
    }
}

// MARK: - TableRegion + Codable

extension TableRegion: Codable {

    static let knownKeys: Set<String> = ["id", "styleId", "minR", "maxR", "minC", "maxC"]

    private enum CodingKeys: String, CodingKey {
        case id, styleId, minR, maxR, minC, maxC
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        styleId = try container.decode(String.self, forKey: .styleId)
        minR = try container.decode(Int.self, forKey: .minR)
        maxR = try container.decode(Int.self, forKey: .maxR)
        minC = try container.decode(Int.self, forKey: .minC)
        maxC = try container.decode(Int.self, forKey: .maxC)
        unknownFields = try UnknownFields(from: decoder, excluding: Self.knownKeys)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(styleId, forKey: .styleId)
        try container.encode(minR, forKey: .minR)
        try container.encode(maxR, forKey: .maxR)
        try container.encode(minC, forKey: .minC)
        try container.encode(maxC, forKey: .maxC)
        try unknownFields.encode(to: encoder, excluding: Self.knownKeys)
    }
}

// MARK: - Registering

extension Array where Element == TableRegion {

    /// Drops every region overlapping `range`.
    ///
    /// Replace-on-overlap rather than a real region merge, which is what the web app's
    /// `useTableRegions` does and says it does: two overlapping tables have no meaningful union,
    /// and the newer one is the one the user just asked for.
    func removingOverlaps(with range: CellRange) -> [TableRegion] {
        filter { !$0.overlaps(range) }
    }

    /// The list with `region` replacing anything it overlaps.
    func registering(_ region: TableRegion) -> [TableRegion] {
        removingOverlaps(with: region.range) + [region]
    }
}
