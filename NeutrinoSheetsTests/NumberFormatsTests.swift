import XCTest
@testable import NeutrinoSheets

/// Epic 9 — "Number formats and the custom-format dialog".
///
/// Two things are asserted, and they are different: that a pattern *renders* the way the browser
/// renders it, and that choosing it leaves behind the same three style keys the browser's dialog
/// leaves. The second is the one that fails quietly — a cell that looks right on the phone but
/// carries a stale `decimalPlaces` reads differently the moment the pattern is removed.
final class NumberFormatsTests: XCTestCase {

    // MARK: - Categories

    func testACellsFormatChoosesItsCategory() {
        XCTAssertEqual(NumberFormats.Category.forNumberFormat("currency"), .currency)
        XCTAssertEqual(NumberFormats.Category.forNumberFormat("percent"), .percent)
        // `date` and `time` predate the merged Date & Time tab and still appear in saved files.
        XCTAssertEqual(NumberFormats.Category.forNumberFormat("date"), .datetime)
        XCTAssertEqual(NumberFormats.Category.forNumberFormat("time"), .datetime)
        XCTAssertEqual(NumberFormats.Category.forNumberFormat("datetime"), .datetime)
        XCTAssertEqual(NumberFormats.Category.forNumberFormat(nil), .number)
        XCTAssertEqual(NumberFormats.Category.forNumberFormat("something-new"), .number)
    }

    func testEveryCategoryHasPresetsAndEveryPatternIsUnique() {
        for category in NumberFormats.Category.allCases {
            XCTAssertFalse(NumberFormats.presets(for: category).isEmpty, "\(category)")
        }
        let patterns = NumberFormats.allPresets.map(\.customFormat)
        XCTAssertEqual(Set(patterns).count, patterns.count)
    }

    // MARK: - The patch

    func testAKnownPatternBringsItsFormatAndDecimalsWithIt() {
        let patch = NumberFormats.patch(forPattern: "#,##0.00", category: .number)

        XCTAssertEqual(patch.numberFormat, .set("number"))
        XCTAssertEqual(patch.decimalPlaces, .set(2))
        XCTAssertEqual(patch.customFormat, .set("#,##0.00"))
    }

    /// A date preset carries no decimal count, so the key is *removed* rather than left at
    /// whatever an earlier currency format put there.
    func testADatePatternClearsDecimalPlaces() {
        let patch = NumberFormats.patch(forPattern: "mmm yyyy", category: .datetime)

        XCTAssertEqual(patch.numberFormat, .set("date"))
        XCTAssertEqual(patch.decimalPlaces, .clear)

        var previous = CellStyle()
        previous.decimalPlaces = 4
        XCTAssertNil(patch.applied(to: previous)?.decimalPlaces)
    }

    /// A hand-typed pattern falls back to the open tab, which is what makes a custom date pattern
    /// store as a date rather than as a number.
    func testAnUnknownPatternTakesTheCategorysFormat() {
        let patch = NumberFormats.patch(forPattern: "dd.mm.yyyy", category: .datetime)

        XCTAssertEqual(patch.numberFormat, .set("datetime"))
        XCTAssertEqual(patch.decimalPlaces, .clear)
        XCTAssertEqual(patch.customFormat, .set("dd.mm.yyyy"))
    }

    func testAnEmptyPatternRemovesTheCustomFormat() {
        let patch = NumberFormats.patch(forPattern: "", category: .currency)

        XCTAssertEqual(patch.customFormat, .clear)
        XCTAssertEqual(patch.numberFormat, .set("currency"))
    }

    // MARK: - Rendering

    /// Every preset has to render through ``CellFormatter``, or the dialog offers formats the grid
    /// cannot draw.
    func testEveryPresetRendersItsOwnSample() {
        for category in NumberFormats.Category.allCases {
            for preset in NumberFormats.presets(for: category) {
                let rendered = NumberFormats.preview(pattern: preset.customFormat, category: category)
                XCTAssertFalse(rendered.isEmpty, preset.customFormat)
                // A pattern that failed to apply comes back as the raw sample, which is the
                // formatter's "this is not a format I understand" answer.
                XCTAssertNotEqual(rendered, category.sample, preset.customFormat)
            }
        }
    }

    func testThePreviewMatchesTheLabelsThePresetsAdvertise() {
        // Spot-checked against the browser's own dialog, one per category.
        XCTAssertEqual(NumberFormats.preview(pattern: "#,##0.00", category: .number), "1,234.57")
        XCTAssertEqual(NumberFormats.preview(pattern: "0.00%", category: .percent), "123,456.78%")
        XCTAssertEqual(NumberFormats.preview(pattern: "mmm yyyy", category: .datetime), "Nov 2025")
        XCTAssertEqual(NumberFormats.preview(pattern: "h:mm AM/PM", category: .datetime), "1:30 PM")
    }

    func testAnEmptyPatternPreviewsTheSampleUnchanged() {
        XCTAssertEqual(NumberFormats.preview(pattern: "", category: .number),
                       NumberFormats.Category.number.sample)
    }

    // MARK: - Quick formats

    func testTheQuickFormatsAreTheOnesTheGridCanRender() {
        XCTAssertEqual(NumberFormats.quickFormats.map(\.id), ["currency", "percent", "number"])
        for format in NumberFormats.quickFormats {
            var style = CellStyle()
            style.numberFormat = format.id
            XCTAssertNotEqual(CellFormatter.display("1234.5", style: style), "1234.5",
                              "\(format.id) should change how the value reads")
        }
    }
}
