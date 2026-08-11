import XCTest
@testable import NeutrinoSheets

/// Number and date formatting, ported from the web app's `formatCellValue` / `applyCustomFormat`.
///
/// Every expectation here is what a browser shows for the same cell. The web app hard-codes
/// `en-US` and UTC in all of those calls, so these assertions are locale- and zone-independent by
/// construction — and a regression that made them follow the device would fail here rather than in
/// front of a user in Berlin.
final class CellFormatterTests: XCTestCase {

    private func style(numberFormat: String? = nil, decimalPlaces: Int? = nil,
                       customFormat: String? = nil) -> CellStyle {
        var style = CellStyle()
        style.numberFormat = numberFormat
        style.decimalPlaces = decimalPlaces
        style.customFormat = customFormat
        return style
    }

    // MARK: - Pass-through

    func testUnstyledValuesAreShownAsStored() {
        XCTAssertEqual(CellFormatter.display("hello", style: nil), "hello")
        XCTAssertEqual(CellFormatter.display("1234.5", style: nil), "1234.5")
        XCTAssertEqual(CellFormatter.display("", style: nil), "")
        XCTAssertEqual(CellFormatter.display(nil, style: nil), "")
    }

    func testNonNumericValuesUnderANumericFormatAreLeftAlone() {
        // The web app returns the raw text rather than showing NaN.
        XCTAssertEqual(CellFormatter.display("N/A", style: style(numberFormat: "currency")), "N/A")
    }

    // MARK: - Numbers

    func testNumberFormat() {
        XCTAssertEqual(CellFormatter.display("1234.567", style: style(numberFormat: "number")), "1,235")
        XCTAssertEqual(
            CellFormatter.display("1234.567", style: style(numberFormat: "number", decimalPlaces: 2)),
            "1,234.57"
        )
    }

    func testCurrencyDefaultsToTwoDecimals() {
        // `decimalPlaces ?? (numberFormat === 'currency' ? 2 : 0)` — currency is the one format
        // whose default is not zero.
        XCTAssertEqual(CellFormatter.display("1250.5", style: style(numberFormat: "currency")),
                       "$1,250.50")
        XCTAssertEqual(
            CellFormatter.display("1250.5", style: style(numberFormat: "currency", decimalPlaces: 0)),
            "$1,251"
        )
    }

    /// The percent style *multiplies by 100*. Getting this wrong is a silent factor-of-100 error.
    func testPercentMultipliesByOneHundred() {
        XCTAssertEqual(CellFormatter.display("0.25", style: style(numberFormat: "percent")), "25%")
        XCTAssertEqual(
            CellFormatter.display("0.1234", style: style(numberFormat: "percent", decimalPlaces: 1)),
            "12.3%"
        )
    }

    func testNegativeNumbers() {
        XCTAssertEqual(CellFormatter.display("-1234.5",
                                             style: style(numberFormat: "number", decimalPlaces: 2)),
                       "-1,234.50")
    }

    /// `Intl.NumberFormat` rounds half *away from zero*; `NumberFormatter` defaults to banker's
    /// rounding, which would send 1250.5 to 1250 where a browser shows 1251. Every expectation
    /// here was checked against `toLocaleString('en-US')`.
    func testTiesRoundAwayFromZeroAsInJavaScript() {
        let zeroDecimals = style(numberFormat: "number", decimalPlaces: 0)
        XCTAssertEqual(CellFormatter.display("1250.5", style: zeroDecimals), "1,251")
        XCTAssertEqual(CellFormatter.display("1251.5", style: zeroDecimals), "1,252")
        XCTAssertEqual(CellFormatter.display("-1250.5", style: zeroDecimals), "-1,251")
        // Both parities: banker's rounding would give 2 here and 4 below.
        XCTAssertEqual(CellFormatter.display("2.5", style: zeroDecimals), "3")
        XCTAssertEqual(CellFormatter.display("3.5", style: zeroDecimals), "4")
    }

    // MARK: - Excel serials

    func testExcelSerialEpoch() {
        // Serial 1 is 1 Jan 1900.
        let day1 = CellFormatter.date(fromExcelSerial: 1)
        XCTAssertEqual(CellFormatter.display(String(1), style: style(numberFormat: "date")),
                       "1/1/1900")
        XCTAssertEqual(day1.timeIntervalSince1970, -2_208_988_800, accuracy: 1)
    }

    /// Excel thinks 1900 was a leap year, so serials past 60 are a day ahead of the real calendar.
    /// The web app compensates, and matching it matters more than being right about 1900.
    func testExcelLeapYearBugIsReproduced() {
        // Serial 45000 is 15 March 2023 — the value a browser shows for the same cell.
        XCTAssertEqual(CellFormatter.display("45000", style: style(numberFormat: "date")),
                       "3/15/2023")
        // Round trip through the serial and back.
        let date = CellFormatter.date(fromExcelSerial: 45_000)
        XCTAssertEqual(CellFormatter.excelSerial(from: date), 45_000, accuracy: 0.0001)
    }

    func testFractionalSerialsCarryTimeOfDay() {
        // .5625 of a day is 13:30.
        XCTAssertEqual(CellFormatter.display("45000.5625", style: style(numberFormat: "time")),
                       "1:30:00 PM")
    }

    // MARK: - Date strings

    func testParsesIsoAndUsDateStrings() {
        XCTAssertEqual(CellFormatter.serial(fromDateString: "2026-01-01"),
                       CellFormatter.serial(fromDateString: "01/01/2026"))
        XCTAssertNotNil(CellFormatter.serial(fromDateString: "2026-01-01 13:30"))
        XCTAssertNotNil(CellFormatter.serial(fromDateString: "01/01/2026 1:30 PM"))
        XCTAssertNotNil(CellFormatter.serial(fromDateString: "2026-01-01T13:30:00"))
    }

    func testBareTimesAreAFractionOfADay() {
        let noon = try? XCTUnwrap(CellFormatter.serial(fromDateString: "12:00"))
        XCTAssertEqual(noon ?? 0, 0.5, accuracy: 0.0001)
    }

    func testRejectsCalendarOverflow() {
        // 30 February must not roll forward into March.
        XCTAssertNil(CellFormatter.serial(fromDateString: "02/30/2026"))
        XCTAssertNil(CellFormatter.serial(fromDateString: "2026-13-01"))
        XCTAssertNil(CellFormatter.serial(fromDateString: "25:00"))
        XCTAssertNil(CellFormatter.serial(fromDateString: "not a date"))
    }

    func testTwoDigitYearsPivotAtFifty() {
        // `y < 50 ? 2000 : 1900`, as the web app has it.
        let y26 = CellFormatter.serial(fromDateString: "01/01/26")
        let y2026 = CellFormatter.serial(fromDateString: "01/01/2026")
        XCTAssertEqual(y26, y2026)

        let y60 = CellFormatter.serial(fromDateString: "01/01/60")
        let y1960 = CellFormatter.serial(fromDateString: "01/01/1960")
        XCTAssertEqual(y60, y1960)
    }

    // MARK: - Date presets

    func testDateTimeAndDateTimePresets() {
        XCTAssertEqual(CellFormatter.display("2026-08-10", style: style(numberFormat: "date")),
                       "8/10/2026")
        XCTAssertEqual(CellFormatter.display("2026-08-10 13:30:00",
                                             style: style(numberFormat: "datetime")),
                       "8/10/2026, 1:30:00 PM")
        XCTAssertEqual(CellFormatter.display("13:30:00", style: style(numberFormat: "time")),
                       "1:30:00 PM")
    }

    // MARK: - Custom formats

    func testCustomNumericFormats() {
        XCTAssertEqual(CellFormatter.display("1234.5", style: style(customFormat: "#,##0.00")),
                       "1,234.50")
        XCTAssertEqual(CellFormatter.display("1234.5", style: style(customFormat: "$#,##0.00")),
                       "$1,234.50")
        XCTAssertEqual(CellFormatter.display("0.256", style: style(customFormat: "0.0%")),
                       "25.6%")
    }

    func testCustomFormatOverridesTheNumberFormatPreset() {
        // `if (style?.customFormat) return applyCustomFormat(...)` comes first in the web app.
        var s = style(numberFormat: "currency", decimalPlaces: 2)
        s.customFormat = "0.000"
        XCTAssertEqual(CellFormatter.display("1.5", style: s), "1.500")
    }

    func testCustomDateFormats() {
        XCTAssertEqual(CellFormatter.display("2026-08-10", style: style(customFormat: "yyyy-mm-dd")),
                       "2026-08-10")
        XCTAssertEqual(CellFormatter.display("2026-08-10", style: style(customFormat: "dd mmm yyyy")),
                       "10 Aug 2026")
        XCTAssertEqual(CellFormatter.display("2026-08-10", style: style(customFormat: "dddd")),
                       "Monday")
    }

    /// `m` means month on its own and minute beside an hour or seconds token. This is the rule most
    /// easily got wrong, and it is wrong *quietly* — a date shows a plausible number either way.
    func testMonthVersusMinuteDisambiguation() {
        let value = "2026-08-10 13:05:09"
        // Beside `hh`, `mm` is minutes.
        XCTAssertEqual(CellFormatter.display(value, style: style(customFormat: "hh:mm:ss")),
                       "13:05:09")
        // On its own, `mm` is the month.
        XCTAssertEqual(CellFormatter.display(value, style: style(customFormat: "mm/dd")),
                       "08/10")
        // Both in one pattern.
        XCTAssertEqual(CellFormatter.display(value, style: style(customFormat: "mm/dd hh:mm")),
                       "08/10 13:05")
    }

    func testMeridiemSwitchesToTwelveHourClock() {
        let value = "2026-08-10 13:05:00"
        XCTAssertEqual(CellFormatter.display(value, style: style(customFormat: "h:mm AM/PM")),
                       "1:05 PM")
        XCTAssertEqual(CellFormatter.display(value, style: style(customFormat: "h:mm am/pm")),
                       "1:05 pm")
        // Midnight is 12, not 0, on a 12-hour clock.
        XCTAssertEqual(CellFormatter.display("2026-08-10 00:30:00",
                                             style: style(customFormat: "h:mm AM/PM")),
                       "12:30 AM")
    }

    func testQuotedLiteralsAreNotTokenised() {
        // The `d` in "day" must survive as text rather than becoming the day number.
        XCTAssertEqual(
            CellFormatter.display("2026-08-10", style: style(customFormat: #"dd "day of" mmmm"#)),
            "10 day of August"
        )
    }

    func testUnparseableValuesFallBackToTheStoredText() {
        XCTAssertEqual(CellFormatter.display("hello", style: style(customFormat: "yyyy-mm-dd")),
                       "hello")
        XCTAssertEqual(CellFormatter.display("hello", style: style(customFormat: "#,##0.00")),
                       "hello")
    }

    // MARK: - parseFloat semantics

    func testNumberParsingMatchesParseFloat() {
        XCTAssertEqual(CellFormatter.parseNumber("42"), 42)
        XCTAssertEqual(CellFormatter.parseNumber("-3.5"), -3.5)
        XCTAssertEqual(CellFormatter.parseNumber("1e3"), 1000)
        // Trailing junk is ignored, leading junk is not — that is what `parseFloat` does.
        XCTAssertEqual(CellFormatter.parseNumber("12abc"), 12)
        XCTAssertNil(CellFormatter.parseNumber("abc12"))
        XCTAssertNil(CellFormatter.parseNumber(""))
    }
}
