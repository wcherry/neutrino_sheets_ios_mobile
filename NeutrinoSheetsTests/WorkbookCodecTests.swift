import XCTest
@testable import NeutrinoSheets

/// Epic 5 — the workbook codec. The format is the contract with the web app, so these are the tests
/// that stop a mobile save destroying work done in a browser.
final class WorkbookCodecTests: XCTestCase {

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
        let file = SheetFile.decode(from: Data(webWorkbookJSON.utf8))

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
        let file = SheetFile.decode(from: Data(webWorkbookJSON.utf8))
        let cells = file.sheets[0].cells

        XCTAssertEqual(cells["C1"]?.colSpan, 2)
        XCTAssertEqual(cells["C1"]?.rowSpan, 2)
        XCTAssertEqual(cells["D2"]?.mergeAnchor, "C1")
        XCTAssertTrue(cells["D2"]?.isMergedAway ?? false)
        XCTAssertFalse(cells["C1"]?.isMergedAway ?? true)
    }

    func testColumnWidthsAreKeyedByZeroBasedIndex() throws {
        let file = SheetFile.decode(from: Data(webWorkbookJSON.utf8))
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
        var file = SheetFile.decode(from: Data(webWorkbookJSON.utf8))

        // Make an edit, exactly as the editor would.
        file.sheets[0].cells["A2"] = SavedCell(id: "A2", raw: "Costs", value: "Costs")

        let reencoded = try file.encoded()
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

    func testPreservesUnknownTopLevelKeys() throws {
        let json = #"{"sheets":[{"cells":{}}],"schemaVersion":3,"lastEditor":"web"}"#
        let file = SheetFile.decode(from: Data(json.utf8))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        XCTAssertEqual(object["lastEditor"] as? String, "web")
    }

    /// A whole-valued number must not come back as `400.0`. Not data loss, but it would make every
    /// mobile save a diff against the same workbook saved on the web.
    func testWholeNumbersRoundTripAsIntegers() throws {
        let json = #"{"sheets":[{"cells":{},"charts":[{"width":400,"ratio":1.5}]}]}"#
        let file = SheetFile.decode(from: Data(json.utf8))
        let text = String(decoding: try file.encoded(), as: UTF8.self)

        XCTAssertTrue(text.contains("\"width\":400"), text)
        XCTAssertFalse(text.contains("400.0"), text)
        XCTAssertTrue(text.contains("\"ratio\":1.5"), text)
    }

    // MARK: - Byte stability

    /// Epic 5 — "Round-trip fixtures … asserted byte-stable". Decode, encode, decode, encode: the
    /// two encodings must be identical, or nothing else here can assert anything.
    func testRoundTripIsByteStable() throws {
        let first = SheetFile.decode(from: Data(webWorkbookJSON.utf8))
        let firstBytes = try first.encoded()
        let second = SheetFile.decode(from: firstBytes)
        let secondBytes = try second.encoded()

        XCTAssertEqual(firstBytes, secondBytes)
    }

    func testDoesNotEmitEmptyOptionalContainers() throws {
        // The web app omits `colWidths` entirely when there are no overrides. Emitting `{}` would
        // differ from what a browser writes for the same workbook.
        let file = SheetFile(sheets: [SheetData(name: "Sheet1", cells: [:], colWidths: [:])])
        let text = String(decoding: try file.encoded(), as: UTF8.self)

        XCTAssertFalse(text.contains("colWidths"), text)
        XCTAssertFalse(text.contains("rowHeights"), text)
        XCTAssertTrue(text.contains("\"cells\":{}"), text)
    }

    // MARK: - Lenient decode (Risk 4)

    /// Every brand-new spreadsheet holds this, because `POST /drive/files` seeds
    /// `native_types::EMPTY_SHEET_CONTENT` — a FortuneSheet-shaped *array*, not `{"sheets":[…]}`.
    /// A strict decoder would fail to open every spreadsheet the moment it was created.
    func testDecodesTheServersSeededDefaultBody() throws {
        let seeded = #"[{"index":"0","name":"Sheet1","celldata":[],"row":100,"column":26,"order":0,"status":1,"config":{}}]"#

        let file = SheetFile.decode(from: Data(seeded.utf8))

        XCTAssertEqual(file.sheets.count, 1)
        XCTAssertEqual(file.sheets[0].name, "Sheet1")
        XCTAssertTrue(file.sheets[0].cells.isEmpty)
    }

    func testDecodesUnrecognisedBodiesAsAnEmptyWorkbook() throws {
        // Matches the web editor's `catch { /* empty sheet, start fresh */ }`.
        for body in ["", "not json at all", "{}", "null", #"{"sheets":[]}"#] {
            let file = SheetFile.decode(from: Data(body.utf8))
            XCTAssertTrue(file.sheets.isEmpty || file.sheets.count == 1,
                          "unexpected sheets for body: \(body)")
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
        let file = SheetFile.decode(from: Data(webWorkbookJSON.utf8))
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
