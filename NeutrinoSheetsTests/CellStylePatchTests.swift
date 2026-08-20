import XCTest
@testable import NeutrinoSheets

/// Epic 9 — the patch semantics every formatting command is built on.
///
/// The case worth the most attention is ``StyleUpdate/clear``. The web app erases a style field by
/// spreading a key whose value is `undefined`, and a Swift patch of plain optionals cannot say the
/// difference between that and "not in this patch" — so every clear would silently become a no-op
/// and "Clear formatting" would do nothing at all.
final class CellStylePatchTests: XCTestCase {

    // MARK: - Update resolution

    func testUnchangedKeepsWhatWasThere() {
        XCTAssertEqual(StyleUpdate<String>.unchanged.resolve("bold"), "bold")
        XCTAssertNil(StyleUpdate<String>.unchanged.resolve(nil))
    }

    func testSetOverwritesAndClearRemoves() {
        XCTAssertEqual(StyleUpdate.set("italic").resolve("normal"), "italic")
        XCTAssertNil(StyleUpdate<String>.clear.resolve("italic"))
    }

    func testOptionalInitMapsNilToClear() {
        XCTAssertEqual(StyleUpdate("#ff0000").resolve(nil), "#ff0000")
        XCTAssertNil(StyleUpdate<String>(nil).resolve("#ff0000"))
    }

    // MARK: - Applying

    func testPatchLeavesUnmentionedFieldsAlone() {
        var style = CellStyle()
        style.fontWeight = "bold"
        style.backgroundColor = "#eef2ff"

        let result = CellStylePatch.italic(true).applied(to: style)

        XCTAssertEqual(result?.fontStyle, "italic")
        XCTAssertEqual(result?.fontWeight, "bold")
        XCTAssertEqual(result?.backgroundColor, "#eef2ff")
    }

    func testPatchAppliesToACellWithNoStyleYet() {
        let result = CellStylePatch.bold(true).applied(to: nil)
        XCTAssertEqual(result?.fontWeight, "bold")
    }

    /// The web app writes `"normal"` rather than removing the key, and a workbook is compared
    /// against the browser's bytes.
    func testUnbondingWritesNormalRatherThanRemovingTheKey() {
        var style = CellStyle()
        style.fontWeight = "bold"

        let result = CellStylePatch.bold(false).applied(to: style)

        XCTAssertEqual(result?.fontWeight, "normal")
    }

    func testClearFormattingRemovesTheStyleEntirely() {
        var style = CellStyle()
        style.fontWeight = "bold"
        style.color = "#111111"
        style.numberFormat = "currency"
        style.decimalPlaces = 2
        style.customFormat = "#,##0.00"
        style.borderStyle = "thin"
        style.borderLeft = "thick"
        style.wrapMode = "wrap"

        // Nil rather than an empty object: the cell drops its `cellStyle` key, which is what the
        // web app's serialiser produces and what the round-trip fixtures assert.
        XCTAssertNil(CellStylePatch.clearFormatting.applied(to: style))
    }

    func testAPatchThatEmptiesTheLastFieldReturnsNil() {
        var style = CellStyle()
        style.color = "#111111"

        XCTAssertNil(CellStylePatch.textColor(nil).applied(to: style))
    }

    // MARK: - Fonts

    /// The size is written in points because the web app's dropdown reads it back by stripping
    /// `pt`; a size in pixels would leave its own toolbar blank.
    func testFontSizeIsWrittenInPoints() {
        let result = CellStylePatch.fontSize(18).applied(to: nil)
        XCTAssertEqual(result?.fontSize, "18pt")
        XCTAssertEqual(result?.pointSize, 18)
    }

    func testFontFamilyStoresTheCSSStackVerbatim() {
        let result = CellStylePatch.fontFamily("'Times New Roman', serif").applied(to: nil)
        XCTAssertEqual(result?.fontFamily, "'Times New Roman', serif")
    }

    // MARK: - Borders

    /// A per-side value wins over `borderStyle` when the grid draws, so an all-sides command that
    /// left one behind would not apply on that edge — a border the user cannot get rid of.
    func testAllBordersClearsThePerSideOverrides() {
        var style = CellStyle()
        style.borderLeft = "thick"
        style.borderTop = "medium"

        let result = CellStylePatch.allBorders("thin").applied(to: style)

        XCTAssertEqual(result?.borderStyle, "thin")
        XCTAssertNil(result?.borderLeft)
        XCTAssertNil(result?.borderTop)
        XCTAssertEqual(result?.border(.left), "thin")
    }

    func testNoBordersIsStoredAsNoneRatherThanAbsent() {
        var style = CellStyle()
        style.borderStyle = "medium"

        let result = CellStylePatch.allBorders(nil).applied(to: style)

        XCTAssertEqual(result?.borderStyle, "none")
        // `border(_:)` reads "none" as no border, which is how the renderer skips it.
        XCTAssertNil(result?.border(.top))
    }

    func testASingleSideLeavesTheOthers() {
        var style = CellStyle()
        style.borderStyle = "thin"

        let result = CellStylePatch.border(.bottom, "thick").applied(to: style)

        XCTAssertEqual(result?.borderBottom, "thick")
        XCTAssertEqual(result?.border(.bottom), "thick")
        // The other three still fall back to the all-sides weight.
        XCTAssertEqual(result?.border(.top), "thin")
        XCTAssertNil(result?.borderTop)
    }

    // MARK: - Emptiness

    func testAnEmptyPatchIsRecognisedAsSuch() {
        XCTAssertTrue(CellStylePatch().isEmpty)
        XCTAssertFalse(CellStylePatch.bold(true).isEmpty)
        XCTAssertFalse(CellStylePatch.clearFormatting.isEmpty)
    }

    func testAnEmptyStyleIsRecognisedAsSuch() {
        XCTAssertTrue(CellStyle().isEmpty)
        var style = CellStyle()
        style.decimalPlaces = 0
        XCTAssertFalse(style.isEmpty)
    }
}
