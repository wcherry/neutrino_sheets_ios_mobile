import XCTest
@testable import NeutrinoSheets

/// A1 addressing, ported from the web app's `numToAlpha` / `alphaToNum` / `parseCellId`. Cheap to
/// test and expensive to get wrong: an off-by-one here misplaces every cell in the grid.
final class CellAddressTests: XCTestCase {

    func testColumnLettersMatchTheWebApp() {
        XCTAssertEqual(CellAddress.columnLetters(1), "A")
        XCTAssertEqual(CellAddress.columnLetters(26), "Z")
        // Bijective base-26: 27 is "AA", not "BA" — the case a plain base conversion gets wrong.
        XCTAssertEqual(CellAddress.columnLetters(27), "AA")
        XCTAssertEqual(CellAddress.columnLetters(52), "AZ")
        XCTAssertEqual(CellAddress.columnLetters(53), "BA")
        XCTAssertEqual(CellAddress.columnLetters(702), "ZZ")
        XCTAssertEqual(CellAddress.columnLetters(703), "AAA")
    }

    func testColumnLettersRoundTrip() {
        for index in [1, 2, 25, 26, 27, 100, 701, 702, 703, 16_384] {
            let letters = CellAddress.columnLetters(index)
            XCTAssertEqual(CellAddress.columnIndex(fromLetters: letters), index,
                           "round trip failed for \(index) (\(letters))")
        }
    }

    func testParsesA1References() {
        XCTAssertEqual(CellAddress("A1"), CellAddress(column: 1, row: 1))
        XCTAssertEqual(CellAddress("Z9"), CellAddress(column: 26, row: 9))
        XCTAssertEqual(CellAddress("AA100"), CellAddress(column: 27, row: 100))
    }

    func testRejectsAnythingThatIsNotAPlainReference() {
        // Lowercase, absolute, ranges, cross-sheet, and empty all mean "not a cell key in this
        // file". Accepting one would put a cell somewhere it does not belong.
        for input in ["a1", "$A$1", "A1:B2", "Sheet1!A1", "", "1A", "A", "1", "A0", "A-1"] {
            XCTAssertNil(CellAddress(input), "should not parse: \(input)")
        }
    }

    func testIdIsTheKeyTheCellIsStoredUnder() {
        XCTAssertEqual(CellAddress(column: 1, row: 1).id, "A1")
        XCTAssertEqual(CellAddress(column: 28, row: 42).id, "AB42")
    }

    func testOffsetClampsToTheGrid() {
        let a1 = CellAddress(column: 1, row: 1)
        XCTAssertEqual(a1.offset(columns: -5, rows: -5), a1)
        XCTAssertEqual(a1.offset(columns: 1, rows: 2), CellAddress(column: 2, row: 3))

        let last = CellAddress(column: CellAddress.maxColumn, row: CellAddress.maxRow)
        XCTAssertEqual(last.offset(columns: 1, rows: 1), last)
    }

    func testOrderingIsRowMajor() {
        XCTAssertTrue(CellAddress("A1")! < CellAddress("B1")!)
        XCTAssertTrue(CellAddress("Z1")! < CellAddress("A2")!)
    }

    // MARK: - Ranges

    func testRangeNormalisesItsCorners() {
        let range = CellRange(CellAddress("C10")!, CellAddress("A1")!)
        XCTAssertEqual(range.start, CellAddress("A1")!)
        XCTAssertEqual(range.end, CellAddress("C10")!)
        XCTAssertEqual(range.address, "A1:C10")
    }

    func testSingleCellRangeAddressIsJustTheCell() {
        let range = CellRange(CellAddress("B2")!, CellAddress("B2")!)
        XCTAssertTrue(range.isSingleCell)
        XCTAssertEqual(range.address, "B2")
    }

    func testRangeContainment() {
        let range = CellRange(CellAddress("B2")!, CellAddress("D4")!)
        XCTAssertTrue(range.contains(CellAddress("C3")!))
        XCTAssertTrue(range.contains(CellAddress("B2")!))
        XCTAssertTrue(range.contains(CellAddress("D4")!))
        XCTAssertFalse(range.contains(CellAddress("A1")!))
        XCTAssertFalse(range.contains(CellAddress("E4")!))
    }
}
