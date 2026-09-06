import XCTest
@testable import NeutrinoSheets

/// Epic 10 — find & replace, and the one rule that keeps it from putting a wrong number into a
/// shared file: a rewritten formula loses its stored result.
final class FindReplaceTests: XCTestCase {

    // MARK: - Helpers

    private func cells(_ entries: [String: String]) -> [String: SavedCell] {
        entries.reduce(into: [:]) { result, entry in
            result[entry.key] = SavedCell(id: entry.key, raw: entry.value, value: entry.value)
        }
    }

    // MARK: - Searching

    func testSearchIsCaseInsensitiveByDefault() {
        let found = FindReplace.matches(in: cells(["A1": "Revenue"]), query: "rev",
                                        options: FindReplace.Options())
        XCTAssertEqual(found.map(\.id), ["A1"])
    }

    func testMatchCaseNarrowsIt() {
        var options = FindReplace.Options()
        options.matchCase = true
        let found = FindReplace.matches(in: cells(["A1": "Revenue"]), query: "rev", options: options)
        XCTAssertTrue(found.isEmpty)
    }

    func testEntireCellRequiresTheWholeEntry() {
        var options = FindReplace.Options()
        options.entireCell = true
        let sheet = cells(["A1": "Revenue", "A2": "Rev"])
        XCTAssertEqual(FindReplace.matches(in: sheet, query: "Rev", options: options).map(\.id),
                       ["A2"])
    }

    func testMatchesComeBackInReadingOrder() {
        // Including past column Z, where sorting ids as text — which is what the browser does —
        // would put AA1 before B1.
        let sheet = cells(["B1": "x", "AA1": "x", "A2": "x"])
        XCTAssertEqual(FindReplace.matches(in: sheet, query: "x",
                                           options: FindReplace.Options()).map(\.id),
                       ["B1", "AA1", "A2"])
    }

    func testAnEmptyQueryMatchesNothing() {
        XCTAssertTrue(FindReplace.matches(in: cells(["A1": "x"]), query: "",
                                          options: FindReplace.Options()).isEmpty)
    }

    func testFormulasAreSearchedAsTheTextTheyWereTypedAs() {
        let sheet = cells(["A1": "=SUM(B1:B9)"])
        XCTAssertEqual(FindReplace.matches(in: sheet, query: "B1:B9",
                                           options: FindReplace.Options()).map(\.id), ["A1"])
    }

    // MARK: - Replacing

    func testReplaceChangesOnlyTheFirstOccurrence() {
        XCTAssertEqual(FindReplace.replacing("a-a-a", query: "a", with: "b",
                                             options: FindReplace.Options(), all: false), "b-a-a")
    }

    func testReplaceAllChangesEveryOccurrence() {
        XCTAssertEqual(FindReplace.replacing("a-a-a", query: "a", with: "b",
                                             options: FindReplace.Options(), all: true), "b-b-b")
    }

    func testReplacingIsCaseInsensitiveWhenTheSearchIs() {
        XCTAssertEqual(FindReplace.replacing("Total total", query: "total", with: "sum",
                                             options: FindReplace.Options(), all: true), "sum sum")
    }

    func testAQueryWithRegexCharactersIsTreatedAsText() {
        // The browser escapes the pattern before building its RegExp; searching a spreadsheet for
        // "(1.5)" has to find that literal string, not match anything-dot-anything.
        XCTAssertEqual(FindReplace.replacing("cost (1.5) x", query: "(1.5)", with: "(2)",
                                             options: FindReplace.Options(), all: true),
                       "cost (2) x")
    }

    // MARK: - Cells

    func testALiteralKeepsItsValueInStepWithItsEntry() {
        let cell = SavedCell(id: "A1", raw: "Revenue", value: "Revenue")
        let replaced = FindReplace.replaced(cell, query: "Revenue", with: "Income",
                                            options: FindReplace.Options(), all: true)
        XCTAssertEqual(replaced?.raw, "Income")
        XCTAssertEqual(replaced?.value, "Income")
    }

    func testARewrittenFormulaDropsItsStaleResult() {
        // There is no evaluator until Epic 15. Keeping "42" beside a formula that no longer
        // produces it is the one outcome that silently corrupts a shared workbook.
        let cell = SavedCell(id: "A1", raw: "=SUM(B1:B9)", value: "42")
        let replaced = FindReplace.replaced(cell, query: "B", with: "C",
                                            options: FindReplace.Options(), all: true)
        XCTAssertEqual(replaced?.raw, "=SUM(C1:C9)")
        XCTAssertNil(replaced?.value)
    }

    func testACellReplacedWithNothingIsRemoved() {
        let cell = SavedCell(id: "A1", raw: "draft", value: "draft")
        XCTAssertNil(FindReplace.replaced(cell, query: "draft", with: "",
                                          options: FindReplace.Options(), all: true))
    }

    func testACellReplacedWithNothingKeepsItsStyle() {
        var cell = SavedCell(id: "A1", raw: "draft", value: "draft")
        cell.cellStyle = CellStyle(fontWeight: "bold")
        let replaced = FindReplace.replaced(cell, query: "draft", with: "",
                                            options: FindReplace.Options(), all: true)
        XCTAssertNil(replaced?.raw)
        XCTAssertEqual(replaced?.cellStyle?.fontWeight, "bold")
    }
}
