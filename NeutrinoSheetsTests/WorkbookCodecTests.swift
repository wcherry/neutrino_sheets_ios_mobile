import XCTest
import NeutrinoOOXML
@testable import NeutrinoSheets

/// Epic 5 — the workbook codec. The format is the contract with the web app, so these are the tests
/// that stop a mobile save destroying work done in a browser.
///
/// Two layers, and both matter. Most of what follows is about the `{"sheets":[…]}` *envelope* — the
/// model the editors share — which is why those tests speak JSON directly. What Drive stores is the
/// `.xlsx` that envelope is carried in; "The stored format" below is where the two meet.
final class WorkbookCodecTests: XCTestCase {

    // MARK: - Helpers

    /// The envelope, decoded as the codec hands it over. `SheetFile.decode(from:)` takes package
    /// bytes now, so a test about the JSON says so.
    private func decodeJSON(_ json: String) throws -> SheetFile {
        try JSONDecoder().decode(SheetFile.self, from: Data(json.utf8))
    }

    // MARK: - Fixtures

    /// A workbook in the shape the web editor writes, carrying every field this app *does* model
    /// plus four it does not (`charts`, `conditionalFormats`, `cfVariables`, `tables`).
    ///
    /// Written out longhand rather than built with the Swift types on purpose: a fixture generated
    /// by the code under test can only ever prove the code agrees with itself.
    private let webWorkbookJSON = """
    {
      "sheets": [
        {
          "name": "Q3",
          "color": "#4f46e5",
          "cells": {
            "A1": {"id":"A1","raw":"Revenue","value":"Revenue",
                   "cellStyle":{"fontWeight":"bold","backgroundColor":"#eef2ff"}},
            "B1": {"id":"B1","raw":"1250.5","value":"1250.5",
                   "cellStyle":{"numberFormat":"currency","decimalPlaces":2,"textAlign":"right"}},
            "B2": {"id":"B2","raw":"=SUM(B1:B1)","value":"1250.5"},
            "C1": {"id":"C1","raw":"Merged","value":"Merged","colSpan":2,"rowSpan":2},
            "D1": {"id":"D1","mergeAnchor":"C1"},
            "C2": {"id":"C2","mergeAnchor":"C1"},
            "D2": {"id":"D2","mergeAnchor":"C1"}
          },
          "colWidths": {"0":180,"2":64},
          "rowHeights": {"0":40},
          "charts": [{"id":"chart-1","type":"column","range":"A1:B2",
                      "options":{"legend":true,"width":400}}],
          "conditionalFormats": [{"id":"cf-1","range":"B1:B9",
                                  "rule":{"kind":"colorScale","minColor":"#fff","maxColor":"#f00"},
                                  "stopIfTrue":false}],
          "cfVariables": [{"name":"Overdue","rule":{"kind":"duplicates","format":{"color":"#b91c1c"}}}],
          "tables": [{"id":"t-1","styleId":"blue","minR":1,"maxR":9,"minC":1,"maxC":2}]
        },
        {
          "name": "Notes",
          "color": null,
          "cells": {}
        }
      ]
    }
    """

    // MARK: - Decoding

    func testDecodesTheWebAppsWorkbookShape() throws {
        let file = try decodeJSON(webWorkbookJSON)

        XCTAssertEqual(file.sheets.count, 2)
        XCTAssertEqual(file.sheets[0].name, "Q3")
        XCTAssertEqual(file.sheets[0].color, "#4f46e5")
        XCTAssertEqual(file.sheets[1].name, "Notes")
        // An explicit `null` colour and an absent one both mean "no colour".
        XCTAssertNil(file.sheets[1].color)

        let cells = file.sheets[0].cells
        XCTAssertEqual(cells["A1"]?.value, "Revenue")
        XCTAssertEqual(cells["A1"]?.cellStyle?.fontWeight, "bold")
        XCTAssertEqual(cells["B1"]?.cellStyle?.numberFormat, "currency")
        XCTAssertEqual(cells["B1"]?.cellStyle?.decimalPlaces, 2)
        // The formula's *raw* and its precomputed *value* are different things, and the viewer
        // depends on the difference.
        XCTAssertEqual(cells["B2"]?.raw, "=SUM(B1:B1)")
        XCTAssertEqual(cells["B2"]?.value, "1250.5")
    }

    func testDecodesMergeSpansAndAnchors() throws {
        let file = try decodeJSON(webWorkbookJSON)
        let cells = file.sheets[0].cells

        XCTAssertEqual(cells["C1"]?.colSpan, 2)
        XCTAssertEqual(cells["C1"]?.rowSpan, 2)
        XCTAssertEqual(cells["D2"]?.mergeAnchor, "C1")
        XCTAssertTrue(cells["D2"]?.isMergedAway ?? false)
        XCTAssertFalse(cells["C1"]?.isMergedAway ?? true)
    }

    func testColumnWidthsAreKeyedByZeroBasedIndex() throws {
        let file = try decodeJSON(webWorkbookJSON)
        let sheet = file.sheets[0]

        // Column index 0 is column A, which is `CellAddress(column: 1, ...)`. Mixing the two
        // conventions would misplace every override by one column.
        XCTAssertEqual(sheet.width(ofColumn: 0), 180)
        XCTAssertEqual(sheet.width(ofColumn: 2), 64)
        XCTAssertNil(sheet.width(ofColumn: 1))
        XCTAssertEqual(sheet.height(ofRow: 0), 40)
    }

    // MARK: - Unknown-field preservation (Risk 3)

    /// The single most destructive thing this app could do: open a workbook made on the web, save
    /// it, and silently drop the charts.
    func testPreservesFieldsTheAppCannotRender() throws {
        var file = try decodeJSON(webWorkbookJSON)

        // Make an edit, exactly as the editor would.
        file.sheets[0].cells["A2"] = SavedCell(id: "A2", raw: "Costs", value: "Costs")

        let reencoded = try file.encodedJSON()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        let sheets = try XCTUnwrap(object["sheets"] as? [[String: Any]])

        let charts = try XCTUnwrap(sheets[0]["charts"] as? [[String: Any]])
        XCTAssertEqual(charts.first?["id"] as? String, "chart-1")
        XCTAssertEqual(charts.first?["type"] as? String, "column")
        // Nested values survive too — preservation is of the whole subtree, not just the top key.
        let options = try XCTUnwrap(charts.first?["options"] as? [String: Any])
        XCTAssertEqual(options["legend"] as? Bool, true)
        XCTAssertEqual(options["width"] as? Int, 400)

        XCTAssertNotNil(sheets[0]["conditionalFormats"])
        XCTAssertNotNil(sheets[0]["cfVariables"])
        XCTAssertNotNil(sheets[0]["tables"])

        // And the edit really did land.
        let cells = try XCTUnwrap(sheets[0]["cells"] as? [String: Any])
        XCTAssertNotNil(cells["A2"])
    }

    // MARK: - Table regions (Epic 9)

    /// `tables` was preserved opaquely until Epic 9 needed to write one. Claiming a key that used
    /// to be carried is the one migration `UnknownFields` is built to survive, and this is what
    /// says it did: the fixture's region comes back typed, with its bounds intact.
    func testDecodesTableRegionsAsTypedValues() throws {
        let file = try decodeJSON(webWorkbookJSON)
        let region = try XCTUnwrap(file.sheets[0].tables?.first)

        XCTAssertEqual(region.id, "t-1")
        XCTAssertEqual(region.styleId, "blue")
        XCTAssertEqual(region.range.address, "A1:B9")
        XCTAssertNil(file.sheets[1].tables)
    }

    func testTableRegionsSurviveAReEncode() throws {
        let file = try decodeJSON(webWorkbookJSON)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try file.encodedJSON()) as? [String: Any]
        )
        let sheets = try XCTUnwrap(object["sheets"] as? [[String: Any]])
        let tables = try XCTUnwrap(sheets[0]["tables"] as? [[String: Any]])

        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0]["id"] as? String, "t-1")
        XCTAssertEqual(tables[0]["minC"] as? Int, 1)
        XCTAssertEqual(tables[0]["maxR"] as? Int, 9)
    }

    /// Forward compatibility one level down: a field a later web release adds *inside* a region is
    /// carried the same way a field it adds to a sheet is.
    func testPreservesUnknownFieldsInsideATableRegion() throws {
        let json = #"""
        {"sheets":[{"cells":{},"tables":[
          {"id":"t-1","styleId":"blue-banded","minR":1,"maxR":4,"minC":1,"maxC":2,
           "headerLabels":["Item","Cost"]}]}]}
        """#
        let file = try decodeJSON(json)
        XCTAssertEqual(file.sheets[0].tables?.first?.styleId, "blue-banded")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try file.encodedJSON()) as? [String: Any]
        )
        let sheets = try XCTUnwrap(object["sheets"] as? [[String: Any]])
        let tables = try XCTUnwrap(sheets[0]["tables"] as? [[String: Any]])
        XCTAssertEqual(tables[0]["headerLabels"] as? [String], ["Item", "Cost"])
    }

    /// A `tables` value in a shape this app cannot read falls back to the opaque path rather than
    /// being dropped. Losing it would not fail anywhere — the range would simply stop being a table
    /// the next time the web app tried to re-band it.
    func testAnUnreadableTablesValueIsStillWrittenBack() throws {
        let json = #"{"sheets":[{"cells":{},"tables":{"legacy":"shape"}}]}"#
        let file = try decodeJSON(json)
        XCTAssertNil(file.sheets[0].tables)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try file.encodedJSON()) as? [String: Any]
        )
        let sheets = try XCTUnwrap(object["sheets"] as? [[String: Any]])
        let tables = try XCTUnwrap(sheets[0]["tables"] as? [String: Any])
        XCTAssertEqual(tables["legacy"] as? String, "shape")
    }

    func testDoesNotEmitAnEmptyTablesArray() throws {
        let file = SheetFile(sheets: [SheetData(name: "Sheet1", tables: [])])
        let text = String(decoding: try file.encodedJSON(), as: UTF8.self)

        XCTAssertFalse(text.contains("tables"), text)
    }

    func testPreservesUnknownTopLevelKeys() throws {
        let json = #"{"sheets":[{"cells":{}}],"schemaVersion":3,"lastEditor":"web"}"#
        let file = try decodeJSON(json)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try file.encodedJSON()) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        XCTAssertEqual(object["lastEditor"] as? String, "web")
    }

    /// A whole-valued number must not come back as `400.0`. Not data loss, but it would make every
    /// mobile save a diff against the same workbook saved on the web.
    func testWholeNumbersRoundTripAsIntegers() throws {
        let json = #"{"sheets":[{"cells":{},"charts":[{"width":400,"ratio":1.5}]}]}"#
        let file = try decodeJSON(json)
        let text = String(decoding: try file.encodedJSON(), as: UTF8.self)

        XCTAssertTrue(text.contains("\"width\":400"), text)
        XCTAssertFalse(text.contains("400.0"), text)
        XCTAssertTrue(text.contains("\"ratio\":1.5"), text)
    }

    // MARK: - Byte stability

    /// Epic 5 — "Round-trip fixtures … asserted byte-stable". Decode, encode, decode, encode: the
    /// two encodings must be identical, or nothing else here can assert anything.
    func testRoundTripIsByteStable() throws {
        let first = try decodeJSON(webWorkbookJSON)
        let firstBytes = try first.encodedJSON()
        let second = try JSONDecoder().decode(SheetFile.self, from: firstBytes)
        let secondBytes = try second.encodedJSON()

        XCTAssertEqual(firstBytes, secondBytes)
    }

    // MARK: - The stored format

    /// What Drive actually holds is an `.xlsx`, and the model has to survive the trip through it —
    /// including the charts this app cannot render, which ride in the package's extras part.
    func testTheStoredFormatIsAnXlsxTheModelSurvives() throws {
        var file = try decodeJSON(webWorkbookJSON)
        file.sheets[0].cells["A2"] = SavedCell(id: "A2", raw: "Costs", value: "Costs")

        let package = try file.encoded()
        XCTAssertTrue(XlsxCodec.isWorkbook(package))

        let back = SheetFile.decode(from: package)
        XCTAssertEqual(back.sheets.count, file.sheets.count)
        XCTAssertEqual(back.sheets[0].cells["A2"]?.raw, "Costs")
        XCTAssertEqual(back.sheets[0].name, file.sheets[0].name)

        // The charts came back, which is the whole point of carrying the extras part.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try back.encodedJSON()) as? [String: Any])
        let sheets = try XCTUnwrap(object["sheets"] as? [[String: Any]])
        let charts = try XCTUnwrap(sheets[0]["charts"] as? [[String: Any]])
        XCTAssertEqual(charts.first?["id"] as? String, "chart-1")
    }

    /// The offline path and the save path both compare stored bytes to decide whether anything
    /// changed, so two encodings of one workbook have to be identical.
    func testTheStoredPackageIsByteStable() throws {
        let file = try decodeJSON(webWorkbookJSON)
        XCTAssertEqual(try file.encoded(), try file.encoded())
    }

    func testDoesNotEmitEmptyOptionalContainers() throws {
        // The web app omits `colWidths` entirely when there are no overrides. Emitting `{}` would
        // differ from what a browser writes for the same workbook.
        let file = SheetFile(sheets: [SheetData(name: "Sheet1", cells: [:], colWidths: [:])])
        let text = String(decoding: try file.encodedJSON(), as: UTF8.self)

        XCTAssertFalse(text.contains("colWidths"), text)
        XCTAssertFalse(text.contains("rowHeights"), text)
        XCTAssertTrue(text.contains("\"cells\":{}"), text)
    }

    // MARK: - Lenient decode (Risk 4)

    /// A spreadsheet created moments ago has no content at all: an `.xlsx` is a zip the server has
    /// no business building, so `POST /drive/files` writes nothing and the client's first save is
    /// what makes the file a real workbook. Opening it in between must show a blank grid, not fail.
    func testAnEmptyBodyDecodesAsAnEmptyWorkbook() {
        let file = SheetFile.decode(from: Data())
        XCTAssertEqual(file.sheets.count, 1)
        XCTAssertTrue(file.sheets[0].cells.isEmpty)
    }

    func testDecodesUnrecognisedBodiesAsAnEmptyWorkbook() {
        // Matches the web editor's `catch { /* empty sheet, start fresh */ }`. The bespoke JSON is
        // in here deliberately: it is no longer a format this app reads.
        for body in ["", "not a package at all", "{}", "null",
                     #"{"sheets":[{"name":"Old","cells":{}}]}"#] {
            let file = SheetFile.decode(from: Data(body.utf8))
            XCTAssertEqual(file.sheets.count, 1, "unexpected sheets for body: \(body)")
            XCTAssertTrue(file.sheets[0].cells.isEmpty, body)
        }
    }

    func testEmptyCellsAreDistinguishedFromPopulatedOnes() {
        XCTAssertTrue(SavedCell(id: "A1").isEmpty)
        XCTAssertTrue(SavedCell(id: "A1", raw: "", value: "").isEmpty)
        XCTAssertFalse(SavedCell(id: "A1", raw: "x").isEmpty)
        // A cell holding only a style is not empty — dropping it would lose the formatting.
        XCTAssertFalse(SavedCell(id: "A1", cellStyle: CellStyle(fontWeight: "bold")).isEmpty)
    }

    // MARK: - Used bounds

    func testUsedBoundsCoverMergeSpans() throws {
        let file = try decodeJSON(webWorkbookJSON)
        let bounds = try XCTUnwrap(file.sheets[0].usedBounds)

        // C1 spans two columns and two rows, so the used area reaches D2 (column 4, row 2).
        XCTAssertEqual(bounds.columns, 4)
        XCTAssertEqual(bounds.rows, 2)
    }

    func testUsedBoundsIsNilForAnEmptySheet() {
        XCTAssertNil(SheetData(name: "Sheet1").usedBounds)
    }
}

// MARK: - CellStyle helpers

private extension CellStyle {
    init(fontWeight: String) {
        self.init()
        self.fontWeight = fontWeight
    }
}
