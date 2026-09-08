import XCTest
import NeutrinoOOXML
@testable import NeutrinoSheets

/// `read(write(m)) == m` over a workbook carrying one of everything.
///
/// The counterpart of `web/apps/web/src/__tests__/sheets/xlsxRoundTrip.test.ts`. The two
/// implementations are one wire format — a spreadsheet written on a phone is opened on the web and
/// the other way round — so the same properties are asserted on both sides.
final class XlsxRoundTripTests: XCTestCase {

    // MARK: - Helpers

    /// Writes `model`, reads it back, and returns the result.
    private func roundTrip(_ model: OOXMLValue) throws -> OOXMLValue {
        let package = try XlsxCodec.encode(model)
        return try XlsxCodec.decode(package)
    }

    /// The first sheet of a round-tripped single-sheet workbook.
    private func roundTripSheet(_ sheet: OOXMLValue) throws -> OOXMLValue {
        let result = try roundTrip(.object(["sheets": .array([sheet])]))
        return try XCTUnwrap(result["sheets"]?.arrayValue?.first)
    }

    private func cell(_ id: String, raw: String, value: String? = nil,
                      style: [String: OOXMLValue]? = nil) -> OOXMLValue {
        var out: [String: OOXMLValue] = [
            "id": .string(id), "raw": .string(raw), "value": .string(value ?? raw),
        ]
        if let style { out["cellStyle"] = .object(style) }
        return .object(out)
    }

    private func sheet(name: String = "Sheet1", cells: [String: OOXMLValue],
                       extra: [String: OOXMLValue] = [:]) -> OOXMLValue {
        var out: [String: OOXMLValue] = ["name": .string(name), "cells": .object(cells)]
        for (key, value) in extra { out[key] = value }
        return .object(out)
    }

    // MARK: - Cells and values

    func testTextNumbersAndFormulasSurvive() throws {
        let result = try roundTripSheet(sheet(cells: [
            "A1": cell("A1", raw: "Widgets"),
            "A2": cell("A2", raw: "42"),
            "A3": cell("A3", raw: "-3.5"),
            "B1": cell("B1", raw: "=SUM(A2:A3)", value: "38.5"),
        ]))
        let cells = try XCTUnwrap(result["cells"]?.objectValue)
        XCTAssertEqual(cells["A1"]?["raw"]?.stringValue, "Widgets")
        XCTAssertEqual(cells["A2"]?["raw"]?.stringValue, "42")
        XCTAssertEqual(cells["A3"]?["raw"]?.stringValue, "-3.5")
        XCTAssertEqual(cells["B1"]?["raw"]?.stringValue, "=SUM(A2:A3)")
        // The cached value rides beside the formula so a reader that does not evaluate still has it.
        XCTAssertEqual(cells["B1"]?["value"]?.stringValue, "38.5")
    }

    /// The case that actually bites: a zip code stored as a number loses its leading zero.
    func testTextThatLooksNumericIsNotConvertedToANumber() throws {
        let result = try roundTripSheet(sheet(cells: [
            "A1": cell("A1", raw: "0015"),
            "A2": cell("A2", raw: "1e5"),
            "A3": cell("A3", raw: "0x1f"),
            "A4": cell("A4", raw: "007"),
        ]))
        let cells = try XCTUnwrap(result["cells"]?.objectValue)
        XCTAssertEqual(cells["A1"]?["raw"]?.stringValue, "0015")
        XCTAssertEqual(cells["A2"]?["raw"]?.stringValue, "1e5")
        XCTAssertEqual(cells["A3"]?["raw"]?.stringValue, "0x1f")
        XCTAssertEqual(cells["A4"]?["raw"]?.stringValue, "007")
    }

    func testNumericValueAcceptsOnlyPlainDecimals() {
        XCTAssertEqual(XlsxWriter.numericValue("0"), 0)
        XCTAssertEqual(XlsxWriter.numericValue("42"), 42)
        XCTAssertEqual(XlsxWriter.numericValue("-3.5"), -3.5)
        XCTAssertEqual(XlsxWriter.numericValue(".5"), 0.5)
        XCTAssertNil(XlsxWriter.numericValue("0015"))
        XCTAssertNil(XlsxWriter.numericValue("5."))
        XCTAssertNil(XlsxWriter.numericValue("1e5"))
        XCTAssertNil(XlsxWriter.numericValue(""))
        XCTAssertNil(XlsxWriter.numericValue("abc"))
    }

    /// A cell holding something XML 1.0 cannot carry must cost that character, not the workbook.
    func testControlCharactersAreStrippedRatherThanBreakingThePackage() throws {
        let result = try roundTripSheet(sheet(cells: [
            "A1": cell("A1", raw: "before\u{0}after"),
            "A2": cell("A2", raw: "a & b < c > d \" e"),
        ]))
        let cells = try XCTUnwrap(result["cells"]?.objectValue)
        XCTAssertEqual(cells["A1"]?["raw"]?.stringValue, "beforeafter")
        XCTAssertEqual(cells["A2"]?["raw"]?.stringValue, "a & b < c > d \" e")
    }

    // MARK: - Styles

    func testEveryCellStylePropertySurvives() throws {
        let style: [String: OOXMLValue] = [
            "fontWeight": .string("bold"),
            "fontStyle": .string("italic"),
            "textDecoration": .string("line-through"),
            "fontSize": .string("14pt"),
            "fontFamily": .string("Georgia"),
            "color": .string("#112233"),
            "backgroundColor": .string("#ffee00"),
            "textAlign": .string("center"),
            "verticalAlign": .string("middle"),
            "wrapMode": .string("wrap"),
            "borderTop": .string("thin"),
            "borderBottom": .string("thick"),
        ]
        let result = try roundTripSheet(sheet(cells: ["A1": cell("A1", raw: "x", style: style)]))
        let back = try XCTUnwrap(result["cells"]?["A1"]?["cellStyle"]?.objectValue)
        for (key, value) in style {
            XCTAssertEqual(back[key], value, "\(key) did not survive")
        }
    }

    /// OOXML has `wrapText` and no third state, so `clip` comes back from the extras part.
    func testClipWrapModeSurvivesThroughTheExtrasPart() throws {
        let result = try roundTripSheet(sheet(cells: [
            "A1": cell("A1", raw: "x", style: ["wrapMode": .string("clip")]),
        ]))
        XCTAssertEqual(result["cells"]?["A1"]?["cellStyle"]?["wrapMode"]?.stringValue, "clip")
    }

    func testStructuredNumberFormatsSurvive() throws {
        let cases: [[String: OOXMLValue]] = [
            ["numberFormat": .string("number"), "decimalPlaces": .number(2)],
            ["numberFormat": .string("currency"), "decimalPlaces": .number(2)],
            ["numberFormat": .string("percent"), "decimalPlaces": .number(1)],
            ["numberFormat": .string("date")],
            ["numberFormat": .string("time")],
            ["numberFormat": .string("datetime")],
        ]
        for style in cases {
            let result = try roundTripSheet(sheet(cells: ["A1": cell("A1", raw: "1", style: style)]))
            let back = try XCTUnwrap(result["cells"]?["A1"]?["cellStyle"]?.objectValue)
            XCTAssertEqual(back["numberFormat"], style["numberFormat"])
            if let decimals = style["decimalPlaces"] {
                XCTAssertEqual(back["decimalPlaces"], decimals)
            }
        }
    }

    /// A code this half-recognised would render differently from the file, so anything that is not
    /// exactly one of ours is carried through verbatim instead.
    func testAnUnrecognisedFormatCodeBecomesACustomFormat() throws {
        let result = try roundTripSheet(sheet(cells: [
            "A1": cell("A1", raw: "1", style: ["customFormat": .string("[Red]#,##0.000;-#,##0.000")]),
        ]))
        XCTAssertEqual(result["cells"]?["A1"]?["cellStyle"]?["customFormat"]?.stringValue,
                       "[Red]#,##0.000;-#,##0.000")
    }

    /// 11pt and Calibri are what a workbook opens at, so recording them would put a font on every
    /// cell of a file that never set one.
    func testTheDefaultFontIsNotRecordedOnEveryCell() throws {
        let result = try roundTripSheet(sheet(cells: [
            "A1": cell("A1", raw: "x", style: ["fontSize": .string("11pt"),
                                               "fontFamily": .string("Calibri")]),
        ]))
        let style = result["cells"]?["A1"]?["cellStyle"]?.objectValue ?? [:]
        XCTAssertNil(style["fontSize"])
        XCTAssertNil(style["fontFamily"])
    }

    /// One `styles.xml` entry however many cells wear it.
    func testIdenticalStylesAreWrittenOnce() throws {
        let style: [String: OOXMLValue] = ["fontWeight": .string("bold")]
        let package = try XlsxCodec.encode(.object(["sheets": .array([sheet(cells: [
            "A1": cell("A1", raw: "a", style: style),
            "A2": cell("A2", raw: "b", style: style),
            "A3": cell("A3", raw: "c", style: style),
        ])])]))
        let zip = try ZipArchive(data: package)
        let styles = try XCTUnwrap(zip.text(for: XlsxMapping.stylesPart))
        // The default plus exactly one bold font.
        XCTAssertEqual(styles.components(separatedBy: "<font>").count - 1, 2)
    }

    // MARK: - Geometry

    func testColumnWidthsAndRowHeightsSurviveInPixels() throws {
        let result = try roundTripSheet(sheet(cells: ["A1": cell("A1", raw: "x")], extra: [
            "colWidths": .object(["0": .number(120), "3": .number(75)]),
            "rowHeights": .object(["0": .number(40)]),
        ]))
        XCTAssertEqual(result["colWidths"]?["0"]?.doubleValue, 120)
        XCTAssertEqual(result["colWidths"]?["3"]?.doubleValue, 75)
        XCTAssertEqual(result["rowHeights"]?["0"]?.doubleValue, 40)
    }

    func testMergesComeBackOnTheAnchorAndEveryCoveredCell() throws {
        var anchor = cell("B2", raw: "merged").objectValue!
        anchor["colSpan"] = .number(2)
        anchor["rowSpan"] = .number(2)
        let result = try roundTripSheet(sheet(cells: ["B2": .object(anchor)]))
        let cells = try XCTUnwrap(result["cells"]?.objectValue)
        XCTAssertEqual(cells["B2"]?["colSpan"]?.intValue, 2)
        XCTAssertEqual(cells["B2"]?["rowSpan"]?.intValue, 2)
        for covered in ["C2", "B3", "C3"] {
            XCTAssertEqual(cells[covered]?["mergeAnchor"]?.stringValue, "B2", covered)
        }
    }

    func testTabNameAndColourSurvive() throws {
        let result = try roundTripSheet(sheet(name: "Q3 Budget", cells: [:],
                                              extra: ["color": .string("#ff8800")]))
        XCTAssertEqual(result["name"]?.stringValue, "Q3 Budget")
        XCTAssertEqual(result["color"]?.stringValue, "#ff8800")
    }

    func testSheetOrderAndCountSurvive() throws {
        let result = try roundTrip(.object(["sheets": .array([
            sheet(name: "One", cells: ["A1": cell("A1", raw: "1")]),
            sheet(name: "Two", cells: ["A1": cell("A1", raw: "2")]),
            sheet(name: "Three", cells: ["A1": cell("A1", raw: "3")]),
        ])]))
        let names = result["sheets"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["One", "Two", "Three"])
    }

    // MARK: - Tab name repair

    /// Excel rejects these outright, and a sheet is named by whoever made it. Repairing is the only
    /// option that keeps the spreadsheet.
    func testTabNamesAreRepairedRatherThanRefused() {
        XCTAssertEqual(XlsxMapping.tabNames(["a/b", "c:d"]), ["a b", "c d"])
        XCTAssertEqual(XlsxMapping.tabNames([""]), ["Sheet1"])
        XCTAssertEqual(XlsxMapping.tabNames(["'quoted'"]), ["quoted"])
        XCTAssertEqual(XlsxMapping.tabNames(["Same", "Same", "Same"]),
                       ["Same", "Same (2)", "Same (3)"])
        XCTAssertEqual(XlsxMapping.tabNames([String(repeating: "x", count: 40)]).first?.count, 31)
    }

    // MARK: - Conditional formats

    /// The kinds OOXML has an operator for come back from the worksheet itself.
    func testNativeConditionalFormatsSurviveTheWorksheet() throws {
        let rules: [OOXMLValue] = [
            .object(["id": .string("r1"), "range": .string("A1:A9"), "rule": .object([
                "kind": .string("singleColor"), "condition": .string("greaterThan"),
                "value": .string("10"),
                "format": .object(["backgroundColor": .string("#ffdcdc")]),
            ])]),
            .object(["id": .string("r2"), "range": .string("B1:B9"), "rule": .object([
                "kind": .string("duplicates"),
                "format": .object(["fontWeight": .string("bold")]),
            ])]),
            .object(["id": .string("r3"), "range": .string("C1:C9"), "rule": .object([
                "kind": .string("iconSet"), "iconSet": .string("arrows"),
            ])]),
        ]
        let result = try roundTripSheet(sheet(cells: [:],
                                              extra: ["conditionalFormats": .array(rules)]))
        let back = try XCTUnwrap(result["conditionalFormats"]?.arrayValue)
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0]["rule"]?["kind"]?.stringValue, "singleColor")
        XCTAssertEqual(back[0]["rule"]?["condition"]?.stringValue, "greaterThan")
        XCTAssertEqual(back[0]["rule"]?["value"]?.stringValue, "10")
        XCTAssertEqual(back[0]["rule"]?["format"]?["backgroundColor"]?.stringValue, "#ffdcdc")
        XCTAssertEqual(back[1]["rule"]?["kind"]?.stringValue, "duplicates")
        XCTAssertEqual(back[2]["rule"]?["iconSet"]?.stringValue, "arrows")
    }

    /// A kind OOXML has no operator for is restored exactly from the extras part, and an
    /// approximation of it is still written so Excel shows the cell as flagged.
    func testExoticConditionalFormatsComeBackExactlyFromTheExtras() throws {
        let progress = OOXMLValue.object([
            "id": .string("r1"), "range": .string("A1:A9"), "rule": .object([
                "kind": .string("progressBar"), "color": .string("#4a7ebb"),
                "minValue": .number(0), "maxValue": .number(250),
                "label": .string("of target"),
            ]),
        ])
        let package = try XlsxCodec.encode(.object(["sheets": .array([
            sheet(cells: [:], extra: ["conditionalFormats": .array([progress])]),
        ])]))

        // Excel sees a data bar rather than nothing at all.
        let zip = try ZipArchive(data: package)
        let worksheet = try XCTUnwrap(zip.text(for: XlsxMapping.worksheetPart(1)))
        XCTAssertTrue(worksheet.contains("type=\"dataBar\""), worksheet)

        // The editor gets the rule it wrote, label and all.
        let back = try XCTUnwrap(XlsxCodec.decode(package)["sheets"]?[0]?["conditionalFormats"]?
            .arrayValue)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0]["rule"]?["kind"]?.stringValue, "progressBar")
        XCTAssertEqual(back[0]["rule"]?["maxValue"]?.doubleValue, 250)
        XCTAssertEqual(back[0]["rule"]?["label"]?.stringValue, "of target")
    }

    /// `dateIsPastDue` is the one *condition* OOXML cannot express, so it needs an extras entry even
    /// though its kind is otherwise native.
    func testDateIsPastDueRoundTripsThroughTheExtras() throws {
        let rule = OOXMLValue.object([
            "id": .string("r1"), "range": .string("A1:A9"), "rule": .object([
                "kind": .string("singleColor"), "condition": .string("dateIsPastDue"),
                "format": .object(["color": .string("#8a1414")]),
            ]),
        ])
        let result = try roundTripSheet(sheet(cells: [:],
                                              extra: ["conditionalFormats": .array([rule])]))
        let back = try XCTUnwrap(result["conditionalFormats"]?.arrayValue)
        XCTAssertEqual(back[0]["rule"]?["condition"]?.stringValue, "dateIsPastDue")
    }

    func testNeedsCFExtraSplitsTheNativeKindsFromTheRest() {
        XCTAssertFalse(XlsxMapping.needsCFExtra(kind: "singleColor", condition: "greaterThan"))
        XCTAssertFalse(XlsxMapping.needsCFExtra(kind: "colorScale", condition: nil))
        XCTAssertTrue(XlsxMapping.needsCFExtra(kind: "singleColor", condition: "dateIsPastDue"))
        XCTAssertTrue(XlsxMapping.needsCFExtra(kind: "progressBar", condition: nil))
        XCTAssertTrue(XlsxMapping.needsCFExtra(kind: "themeColor", condition: nil))
        XCTAssertTrue(XlsxMapping.needsCFExtra(kind: "variable", condition: nil))
    }

    /// The extras are indexed by rule order, so a rule that writes nothing would shift every entry
    /// after it. A `variable` rule writes one that never fires instead.
    func testAVariableRuleStillOccupiesItsPosition() throws {
        let rules: [OOXMLValue] = [
            .object(["id": .string("r1"), "range": .string("A1:A9"), "rule": .object([
                "kind": .string("variable"), "variableId": .string("v1"),
            ])]),
            .object(["id": .string("r2"), "range": .string("B1:B9"), "rule": .object([
                "kind": .string("duplicates"), "format": .object(["fontWeight": .string("bold")]),
            ])]),
        ]
        let result = try roundTripSheet(sheet(cells: [:],
                                              extra: ["conditionalFormats": .array(rules)]))
        let back = try XCTUnwrap(result["conditionalFormats"]?.arrayValue)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0]["rule"]?["kind"]?.stringValue, "variable")
        XCTAssertEqual(back[0]["rule"]?["variableId"]?.stringValue, "v1")
        XCTAssertEqual(back[1]["rule"]?["kind"]?.stringValue, "duplicates")
    }

    func testCFVariablesSurvive() throws {
        let variables = OOXMLValue.array([
            .object(["id": .string("v1"), "name": .string("Threshold"), "value": .string("10")]),
        ])
        let result = try roundTripSheet(sheet(cells: [:], extra: ["cfVariables": variables]))
        XCTAssertEqual(result["cfVariables"], variables)
    }

    // MARK: - Tables

    func testATableRegionIsARealTablePartAndKeepsItsNeutrinoStyle() throws {
        let region = OOXMLValue.object([
            "id": .string("t1"), "styleId": .string("stripedBlue"),
            "minR": .number(1), "maxR": .number(5), "minC": .number(1), "maxC": .number(3),
        ])
        let package = try XlsxCodec.encode(.object(["sheets": .array([sheet(cells: [
            "A1": cell("A1", raw: "Region"),
            "B1": cell("B1", raw: "Units"),
            "C1": cell("C1", raw: "Revenue"),
        ], extra: ["tables": .array([region])])])]))

        // A real OOXML table, with the header row as its column names.
        let zip = try ZipArchive(data: package)
        let table = try XCTUnwrap(zip.text(for: XlsxMapping.tablePart(1)))
        XCTAssertTrue(table.contains("ref=\"A1:C5\""), table)
        XCTAssertTrue(table.contains("name=\"Revenue\""), table)

        // The Neutrino style id is not an OOXML concept, so it rides in the extras.
        let back = try XCTUnwrap(XlsxCodec.decode(package)["sheets"]?[0]?["tables"]?.arrayValue)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0]["styleId"]?.stringValue, "stripedBlue")
        XCTAssertEqual(back[0]["minC"]?.intValue, 1)
        XCTAssertEqual(back[0]["maxC"]?.intValue, 3)
        XCTAssertEqual(back[0]["maxR"]?.intValue, 5)
    }

    // MARK: - Charts

    /// No chart is written as an OOXML chart part by either implementation, so this is the one thing
    /// carried whole — and a phone save must not be what deletes a chart made on the web.
    func testChartsAreCarriedWholeThroughASave() throws {
        let charts = OOXMLValue.array([
            .object([
                "id": .string("c1"), "type": .string("waterfall"),
                "range": .string("A1:B10"), "title": .string("Bridge"),
                "annotations": .array([.object(["at": .string("A3"), "text": .string("dip")])]),
            ]),
        ])
        let result = try roundTripSheet(sheet(cells: [:], extra: ["charts": charts]))
        XCTAssertEqual(result["charts"], charts)
    }

    // MARK: - Foreign packages

    /// A workbook that has been through Excel can carry pivot tables and images. Dropping them on
    /// every save would make Neutrino the tool that quietly deletes your pivot table.
    func testUnrecognisedPartsOfAPreviousPackageAreCarried() throws {
        var previous = try ZipArchive(data: XlsxCodec.encode(
            .object(["sheets": .array([sheet(cells: ["A1": cell("A1", raw: "x")])])])))
        previous.set("xl/pivotTables/pivotTable1.xml", text: "<pivot/>")
        previous.set("xl/media/image1.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let previousData = try previous.serialized()

        let package = try XlsxCodec.encode(
            .object(["sheets": .array([sheet(cells: ["A1": cell("A1", raw: "y")])])]),
            keeping: previousData)
        let zip = try ZipArchive(data: package)
        XCTAssertTrue(zip.contains("xl/pivotTables/pivotTable1.xml"))
        XCTAssertEqual(zip.data(for: "xl/media/image1.png"), Data([0x89, 0x50, 0x4E, 0x47]))
        // The parts this writer owns are its own, not the old ones.
        XCTAssertEqual(try XlsxCodec.decode(package)["sheets"]?[0]?["cells"]?["A1"]?["raw"]?
            .stringValue, "y")
    }

    // MARK: - Package shape

    func testAnEmptyWorkbookIsAValidPackageWithOneTab() throws {
        let package = try XlsxCodec.emptyWorkbook()
        let zip = try ZipArchive(data: package)
        // The OPC specification requires the content types to be the first part.
        XCTAssertEqual(zip.names.first, "[Content_Types].xml")
        XCTAssertTrue(zip.contains(XlsxMapping.workbookPart))
        XCTAssertTrue(zip.contains(XlsxMapping.worksheetPart(1)))
        XCTAssertTrue(zip.contains(XlsxMapping.stylesPart))
        XCTAssertEqual(try XlsxCodec.decode(package)["sheets"]?.arrayValue?.count, 1)
    }

    /// A workbook with nothing to park there must not carry an extras part at all.
    func testThePackageHasNoExtrasPartWhenThereAreNoExtras() throws {
        let package = try XlsxCodec.encode(
            .object(["sheets": .array([sheet(cells: ["A1": cell("A1", raw: "x")])])]))
        XCTAssertFalse(try ZipArchive(data: package).contains(XlsxMapping.extrasPart))
    }

    /// The offline cache and the save path both compare stored bytes to decide whether anything
    /// changed, so two writes of one workbook have to be identical.
    func testWritingTheSameWorkbookTwiceIsByteIdentical() throws {
        let model = OOXMLValue.object(["sheets": .array([sheet(cells: [
            "A1": cell("A1", raw: "x", style: ["fontWeight": .string("bold")]),
            "B7": cell("B7", raw: "42"),
        ], extra: ["colWidths": .object(["2": .number(90)])])])])
        XCTAssertEqual(try XlsxCodec.encode(model), try XlsxCodec.encode(model))
    }

    func testDecodingSomethingThatIsNotAWorkbookThrows() {
        XCTAssertThrowsError(try XlsxCodec.decode(Data("not a zip".utf8)))
        XCTAssertFalse(XlsxCodec.isWorkbook(Data("not a zip".utf8)))
    }

    // MARK: - Names

    func testTheExtensionIsAddedAndStrippedIdempotently() {
        XCTAssertEqual(XlsxCodec.withExtension("Budget"), "Budget.xlsx")
        XCTAssertEqual(XlsxCodec.withExtension("Budget.xlsx"), "Budget.xlsx")
        XCTAssertEqual(XlsxCodec.strippingExtension("Budget.xlsx"), "Budget")
        // A file genuinely called this keeps its name; only the modern extension is stripped.
        XCTAssertEqual(XlsxCodec.strippingExtension("Q3.report"), "Q3.report")
        XCTAssertEqual(XlsxCodec.strippingExtension("Book.xls"), "Book.xls")
    }

    // MARK: - Units and colours

    func testUnitConversionsAreStableInBothDirections() {
        for px in [40.0, 75.0, 120.0, 300.0] {
            XCTAssertEqual(XlsxMapping.charWidthToPx(XlsxMapping.pxToCharWidth(px)), px, accuracy: 1)
            XCTAssertEqual(XlsxMapping.pointsToPx(XlsxMapping.pxToPoints(px)), px, accuracy: 1)
        }
    }

    func testColoursNormaliseToTheOneSpellingOOXMLHas() {
        XCTAssertEqual(XlsxMapping.normalizeColor("#ABC"), "#aabbcc")
        XCTAssertEqual(XlsxMapping.normalizeColor("rgb(255, 0, 128)"), "#ff0080")
        XCTAssertEqual(XlsxMapping.normalizeColor("rgba(255, 0, 128, 0.5)"), "#ff0080")
        XCTAssertNil(XlsxMapping.normalizeColor("papayawhip"))
        XCTAssertEqual(XlsxMapping.toArgb("#ff0080"), "FFFF0080")
        XCTAssertEqual(XlsxMapping.fromArgb("FFFF0080"), "#ff0080")
    }

    func testCellAddressesParseAndFormat() {
        XCTAssertEqual(XlsxMapping.parseCellID("A1")?.column, 1)
        XCTAssertEqual(XlsxMapping.parseCellID("AA10")?.column, 27)
        XCTAssertEqual(XlsxMapping.parseCellID("AA10")?.row, 10)
        XCTAssertNil(XlsxMapping.parseCellID("1A"))
        XCTAssertNil(XlsxMapping.parseCellID("A"))
        XCTAssertEqual(XlsxMapping.numberToColumn(1), "A")
        XCTAssertEqual(XlsxMapping.numberToColumn(27), "AA")
        XCTAssertEqual(XlsxMapping.numberToColumn(702), "ZZ")
    }
}
