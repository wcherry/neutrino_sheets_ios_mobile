import XCTest
@testable import NeutrinoSheets

/// Epic 8 — relative-reference rewriting for copy / paste and fill.
///
/// This is the part of clipboard support that is a *contract* rather than a convenience: a formula
/// copied on a phone has to shift the same way it would in the browser, or the two clients disagree
/// about what a workbook contains. The cases here are the ones the web app's `encodeFormula` /
/// `decodeFormula` document.
final class FormulaReferencesTests: XCTestCase {

    private func move(_ formula: String, from source: String, to destination: String) -> String {
        FormulaReferences.shift(formula, from: CellAddress(source)!, to: CellAddress(destination)!)
    }

    // MARK: - Relative

    func testARelativeReferenceFollowsTheCellItIsCopiedTo() {
        XCTAssertEqual(move("=A1+B1", from: "C1", to: "C2"), "=A2+B2")
        XCTAssertEqual(move("=A1", from: "B1", to: "D1"), "=C1")
        XCTAssertEqual(move("=SUM(A1:A9)", from: "B1", to: "C1"), "=SUM(B1:B9)")
    }

    func testAnAbsoluteReferenceDoesNotMove() {
        XCTAssertEqual(move("=$A$1", from: "C1", to: "F9"), "=$A$1")
    }

    /// The half-absolute forms are where an off-by-one in the encoding shows up, because only one
    /// of the two components moves.
    func testAMixedReferenceMovesOnOneAxisOnly() {
        // C2 → D5 is one column right and three rows down. `A$1` moves its column and pins its
        // row; `$A1` does the opposite.
        XCTAssertEqual(move("=A$1", from: "C2", to: "D5"), "=B$1")
        XCTAssertEqual(move("=$A1", from: "C2", to: "D5"), "=$A4")
    }

    func testANonFormulaIsLeftAlone() {
        XCTAssertEqual(move("A1", from: "C1", to: "C2"), "A1")
        XCTAssertEqual(move("42", from: "C1", to: "C2"), "42")
        XCTAssertEqual(move("", from: "C1", to: "C2"), "")
    }

    // MARK: - Cross-sheet

    /// A bare sheet name is letters followed by digits from a regex's point of view, so an encoder
    /// that did not pull it out first would rewrite `Beta!` into nonsense.
    func testACrossSheetReferenceKeepsItsSheetName() {
        XCTAssertEqual(move("=Beta!C4", from: "A1", to: "A2"), "=Beta!C5")
        XCTAssertEqual(move("='Net Worth'!C4+A1", from: "A1", to: "B1"), "='Net Worth'!D4+B1")
    }

    // MARK: - Out of bounds

    /// A reference dragged off the top or left of the grid is `#REF!`, not a clamp to row 1 — a
    /// clamped reference reads a cell the user never named and looks perfectly healthy doing it.
    func testAReferenceShiftedOffTheGridBecomesRefError() {
        XCTAssertEqual(move("=A1", from: "B2", to: "B1"), "=#REF!")
        XCTAssertEqual(move("=A1", from: "B1", to: "A1"), "=#REF!")
    }

    // MARK: - Encoding

    /// The encoding is a wire format shared with nothing else, so it is asserted directly: a change
    /// to it silently breaks every payload already sitting on a pasteboard.
    func testTheEncodingMatchesTheWebApps() {
        let address = CellAddress(column: 3, row: 2)
        XCTAssertEqual(FormulaReferences.encode("=$A$1", at: address), "=[$A][$1]")
        XCTAssertEqual(FormulaReferences.encode("=A$1", at: address), "=[-2][$1]")
        XCTAssertEqual(FormulaReferences.encode("=$A1", at: address), "=[$A][-1]")
        XCTAssertEqual(FormulaReferences.encode("=A1", at: address), "=[-2][-1]")
    }

    func testDecodingReversesEncoding() {
        let source = CellAddress(column: 4, row: 7)
        for formula in ["=A1+$B$2*C$3-$D4", "=SUM(A1:C3)/AVERAGE($A$1:$A$9)"] {
            let encoded = FormulaReferences.encode(formula, at: source)
            XCTAssertEqual(FormulaReferences.decode(encoded, at: source), formula)
        }
    }

    // MARK: - Detection

    func testFormulaDetectionIgnoresLeadingSpace() {
        XCTAssertTrue(FormulaReferences.isFormula("=SUM(A1:A9)"))
        XCTAssertTrue(FormulaReferences.isFormula("  =A1+1"))
        XCTAssertFalse(FormulaReferences.isFormula("a = b"))
        XCTAssertFalse(FormulaReferences.isFormula("42"))
    }
}
