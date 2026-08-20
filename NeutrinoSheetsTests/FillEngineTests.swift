import XCTest
@testable import NeutrinoSheets

/// Epic 8 — the fill handle's series detection.
///
/// The rules matter more than the mechanism: a user drags a handle and expects Excel's answer, and
/// the places the two could differ — a lone number, a lone date, an uneven run — are what these
/// tests pin down.
final class FillEngineTests: XCTestCase {

    // MARK: - Helpers

    private func sheet(_ values: [String: String]) -> [String: SavedCell] {
        values.reduce(into: [:]) { result, entry in
            result[entry.key] = SavedCell(id: entry.key, raw: entry.value, value: entry.value)
        }
    }

    private func filled(_ cells: [String: SavedCell], from source: String, to target: String)
        -> [String: String?] {
        let changes = FillEngine.fill(source: range(source), target: range(target), cells: cells)
        return changes.mapValues { $0?.raw }
    }

    private func range(_ text: String) -> CellRange {
        let parts = text.split(separator: ":").map(String.init)
        let start = CellAddress(parts[0])!
        return CellRange(start, parts.count > 1 ? CellAddress(parts[1])! : start)
    }

    // MARK: - Numbers

    func testTwoNumbersContinueTheirStep() {
        let result = filled(sheet(["A1": "1", "A2": "2"]), from: "A1:A2", to: "A1:A5")

        XCTAssertEqual(result["A3"], "3")
        XCTAssertEqual(result["A4"], "4")
        XCTAssertEqual(result["A5"], "5")
    }

    func testAStepOtherThanOneIsCarriedThrough() {
        let result = filled(sheet(["A1": "5", "A2": "10", "A3": "15"]), from: "A1:A3", to: "A1:A5")

        XCTAssertEqual(result["A4"], "20")
        XCTAssertEqual(result["A5"], "25")
    }

    /// Excel copies a lone number rather than counting from it, and users rely on that to drag a
    /// constant down a column.
    func testASingleNumberRepeats() {
        let result = filled(sheet(["A1": "7"]), from: "A1", to: "A1:A3")

        XCTAssertEqual(result["A2"], "7")
        XCTAssertEqual(result["A3"], "7")
    }

    func testDecimalsAreKept() {
        let result = filled(sheet(["A1": "1.5", "A2": "2.0"]), from: "A1:A2", to: "A1:A4")

        XCTAssertEqual(result["A3"], "2.5")
        XCTAssertEqual(result["A4"], "3.0")
    }

    /// Fitting a line rather than differencing consecutive values is what lets an uneven run still
    /// produce the trend the user drew, instead of refusing to continue at all.
    func testAnUnevenRunFollowsItsTrend() {
        let result = filled(sheet(["A1": "1", "A2": "2", "A3": "4"]), from: "A1:A3", to: "A1:A4")

        XCTAssertEqual(result["A4"], "5")
    }

    // MARK: - Direction

    func testFillingUpwardsCountsBackwards() {
        let result = filled(sheet(["A5": "10", "A6": "11"]), from: "A5:A6", to: "A3:A6")

        XCTAssertEqual(result["A4"], "9")
        XCTAssertEqual(result["A3"], "8")
    }

    func testFillingSidewaysWalksTheRow() {
        let result = filled(sheet(["A1": "2", "B1": "4"]), from: "A1:B1", to: "A1:D1")

        XCTAssertEqual(result["C1"], "6")
        XCTAssertEqual(result["D1"], "8")
    }

    /// Each column of a multi-column source is its own series — otherwise a two-column table drags
    /// down with one column's numbers leaking into the other.
    func testEachColumnKeepsItsOwnSeries() {
        let cells = sheet(["A1": "1", "A2": "2", "B1": "100", "B2": "200"])

        let result = filled(cells, from: "A1:B2", to: "A1:B3")

        XCTAssertEqual(result["A3"], "3")
        XCTAssertEqual(result["B3"], "300")
    }

    // MARK: - Text

    func testTextWithATrailingNumberCountsUp() {
        let result = filled(sheet(["A1": "Item 1"]), from: "A1", to: "A1:A3")

        XCTAssertEqual(result["A2"], "Item 2")
        XCTAssertEqual(result["A3"], "Item 3")
    }

    func testLeadingZeroesAreKeptWhenCounting() {
        let result = filled(sheet(["A1": "Run 007"]), from: "A1", to: "A1:A3")

        XCTAssertEqual(result["A2"], "Run 008")
        XCTAssertEqual(result["A3"], "Run 009")
    }

    func testPlainTextRepeats() {
        let result = filled(sheet(["A1": "Total"]), from: "A1", to: "A1:A3")

        XCTAssertEqual(result["A2"], "Total")
        XCTAssertEqual(result["A3"], "Total")
    }

    /// A block with no series tiles, so copying a two-row pattern down alternates rather than
    /// repeating whichever row happened to be last.
    func testAPatternWithNoSeriesTiles() {
        let result = filled(sheet(["A1": "Yes", "A2": "No"]), from: "A1:A2", to: "A1:A6")

        XCTAssertEqual(result["A3"], "Yes")
        XCTAssertEqual(result["A4"], "No")
        XCTAssertEqual(result["A5"], "Yes")
    }

    // MARK: - Names

    func testMonthsContinue() {
        let result = filled(sheet(["A1": "Jan", "A2": "Feb"]), from: "A1:A2", to: "A1:A4")

        XCTAssertEqual(result["A3"], "Mar")
        XCTAssertEqual(result["A4"], "Apr")
    }

    func testMonthsWrapAroundTheYear() {
        let result = filled(sheet(["A1": "Nov", "A2": "Dec"]), from: "A1:A2", to: "A1:A4")

        XCTAssertEqual(result["A3"], "Jan")
        XCTAssertEqual(result["A4"], "Feb")
    }

    func testWeekdaysContinueInTheSourcesCase() {
        let result = filled(sheet(["A1": "MONDAY"]), from: "A1", to: "A1:A2")

        XCTAssertEqual(result["A2"], "TUESDAY")
    }

    // MARK: - Dates

    /// Unlike a lone number, a lone date advances — repeating it is never what dragging a date down
    /// a column is asking for.
    func testASingleDateAdvancesByADay() {
        let result = filled(sheet(["A1": "2026-01-30"]), from: "A1", to: "A1:A3")

        XCTAssertEqual(result["A2"], "2026-01-31")
        XCTAssertEqual(result["A3"], "2026-02-01")
    }

    func testADateStepIsCarriedThroughInTheSourcesFormat() {
        let result = filled(sheet(["A1": "01/06/2026", "A2": "01/13/2026"]),
                            from: "A1:A2", to: "A1:A3")

        XCTAssertEqual(result["A3"], "01/20/2026")
    }

    // MARK: - Formulas and styles

    /// A filled formula shifts its references but drops the source's *result*: there is no
    /// evaluator yet, and a stale value would be a wrong number sitting in a shared file. The web
    /// app recomputes every formula on load, so an absent value heals itself there.
    func testAFilledFormulaShiftsItsReferencesAndDropsTheStaleValue() {
        var cells = sheet([:])
        cells["C1"] = SavedCell(id: "C1", raw: "=A1+B1", value: "3")

        let changes = FillEngine.fill(source: range("C1"), target: range("C1:C2"), cells: cells)

        XCTAssertEqual(changes["C2"]??.raw, "=A2+B2")
        XCTAssertNil(changes["C2"]??.value)
    }

    func testStyleTravelsWithTheFill() {
        var style = CellStyle()
        style.fontWeight = "bold"
        var cells = sheet([:])
        cells["A1"] = SavedCell(id: "A1", raw: "1", value: "1", cellStyle: style)

        let changes = FillEngine.fill(source: range("A1"), target: range("A1:A2"), cells: cells)

        XCTAssertEqual(changes["A2"]??.cellStyle?.fontWeight, "bold")
    }

    /// Dragging a blank cell over populated ones clears them. Leaving the old values would make a
    /// fill that shrinks a table quietly keep its last rows.
    func testFillingFromABlankClearsWhatItLandsOn() {
        let changes = FillEngine.fill(source: range("A1"), target: range("A1:A2"),
                                      cells: sheet(["A2": "keep me"]))

        XCTAssertTrue(changes.keys.contains("A2"))
        XCTAssertNil(changes["A2"] ?? nil)
    }

    // MARK: - Guards

    /// A target that grows in both directions has no single series to continue, so nothing is
    /// written rather than something guessed.
    func testADiagonalTargetFillsNothing() {
        let changes = FillEngine.fill(source: range("A1"), target: range("A1:C3"),
                                      cells: sheet(["A1": "1"]))

        XCTAssertTrue(changes.isEmpty)
    }

    func testATargetEqualToTheSourceFillsNothing() {
        let changes = FillEngine.fill(source: range("A1:A3"), target: range("A1:A3"),
                                      cells: sheet(["A1": "1"]))

        XCTAssertTrue(changes.isEmpty)
    }
}
