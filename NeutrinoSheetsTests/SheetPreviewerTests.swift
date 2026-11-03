import XCTest
@testable import NeutrinoSheets

/// Page one's signature: what decides whether an edit redraws the workbook's Drive preview.
@MainActor
final class SheetPreviewerTests: XCTestCase {

    private func sheet(_ cells: [String: String]) -> SheetData {
        var sheet = SheetData(name: "Sheet1")
        for (id, value) in cells {
            sheet.cells[id] = SavedCell(id: id, raw: value, value: value)
        }
        return sheet
    }

    func testAnEditOffPageOneKeepsTheSignature() {
        let base = sheet(["A1": "Item", "B2": "2"])
        let edited = sheet(["A1": "Item", "B2": "2", "A500": "far down", "Z1": "far right"])
        XCTAssertEqual(SheetPreviewer.signature(of: edited), SheetPreviewer.signature(of: base))
    }

    func testAnEditOnPageOneChangesTheSignature() {
        let base = sheet(["A1": "Item"])
        XCTAssertNotEqual(SheetPreviewer.signature(of: sheet(["A1": "Total"])), SheetPreviewer.signature(of: base))
    }

    func testResizingAPageOneColumnChangesTheSignature() {
        let base = sheet(["A1": "Item"])
        var wider = base
        wider.colWidths = ["0": 180]
        XCTAssertNotEqual(SheetPreviewer.signature(of: wider), SheetPreviewer.signature(of: base))
    }
}
