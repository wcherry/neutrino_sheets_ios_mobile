import Foundation

// MARK: - XlsxMapping

/// The vocabulary ``XlsxWriter`` and ``XlsxReader`` share: one spelling per concept, and the tables
/// that turn the sheets editor's model into SpreadsheetML and back.
///
/// This is the Swift half of `web/apps/web/src/lib/ooxml/xlsx/mapping.ts`. **The two are one wire
/// format** — a spreadsheet written on a phone is opened on the web and the other way round — so a
/// change to either belongs in both, and both repositories assert `read(write(m)) == m` over a
/// workbook carrying one of everything.
///
/// ## What OOXML cannot hold
///
/// Three things, and each is a bounded gap rather than a shrug:
///
/// - **Charts.** Neutrino has twenty chart types, annotations and trendlines; OOXML chart parts for
///   those are a project of their own, and no chart is written by either implementation. This is
///   the one thing carried whole.
/// - **The conditional-format kinds OOXML has no operator for** — progress bars, status indicators,
///   heat-map presets, theme tokens and variable references. An approximation *is* written for each,
///   so Excel shows something truthful; the extras entry restores the exact rule.
/// - **Small attributes with no home**: a table's Neutrino style id, `clip` as distinct from
///   `overflow` (OOXML has `wrapText` and no third state), and the CF variable definitions a
///   `variable` rule refers to.
///
/// Those go in `customXml/item1.xml`, addressed by index. Excel keeps `customXml/` parts across an
/// edit, so a workbook that has been through Excel comes back with its extras intact; one *edited*
/// in Excel comes back with the indices no longer lining up, and then the extras are dropped and the
/// base content — which is all real OOXML — still reads.
enum XlsxMapping {

    // MARK: - Namespaces and parts

static let nsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
static let nsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
static let nsPackageRels = "http://schemas.openxmlformats.org/package/2006/relationships"
static let nsContentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"

static let extrasPart = "customXml/item1.xml"
static let extrasPropsPart = "customXml/itemProps1.xml"
static let extrasNamespace = "https://neutrino.app/ns/sheet-extras"

static let workbookPart = "xl/workbook.xml"
static let workbookRelsPart = "xl/_rels/workbook.xml.rels"
static let stylesPart = "xl/styles.xml"
static let sharedStringsPart = "xl/sharedStrings.xml"
static let rootRelsPart = "_rels/.rels"

static func worksheetPart(_ index: Int) -> String { "xl/worksheets/sheet\(index).xml" }
static func worksheetRelsPart(_ index: Int) -> String {
        "xl/worksheets/_rels/sheet\(index).xml.rels"
    }
static func tablePart(_ id: Int) -> String { "xl/tables/table\(id).xml" }

    // MARK: - Cell addressing

    /// `(column, row)` for an A1 address, both 1-based, or nil when it is not one.
static func parseCellID(_ id: String) -> (column: Int, row: Int)? {
        var letters = ""
        var digits = ""
        for character in id {
            if character.isUppercase, character.isLetter, digits.isEmpty {
                letters.append(character)
            } else if character.isNumber {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty, let row = Int(digits), row > 0 else { return nil }
        return (columnToNumber(letters), row)
    }

static func columnToNumber(_ letters: String) -> Int {
        var n = 0
        for scalar in letters.unicodeScalars {
            guard (65...90).contains(scalar.value) else { return 0 }
            n = n * 26 + Int(scalar.value) - 64
        }
        return n
    }

static func numberToColumn(_ number: Int) -> String {
        var n = number
        var out = ""
        while n > 0 {
            n -= 1
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n /= 26
        }
        return out
    }

    // MARK: - Units

    /// Column widths are in "characters of the maximum digit width" in OOXML and CSS pixels in the
    /// editor. Seven pixels per digit plus five of padding is the conversion Excel documents, so a
    /// width written here comes back the same number of pixels.
static func pxToCharWidth(_ px: Double) -> Double { (px - 5) / 7 }
static func charWidthToPx(_ chars: Double) -> Double { (chars * 7 + 5).rounded() }

    /// Row heights are points in OOXML and CSS pixels in the editor: 1px = 0.75pt.
static func pxToPoints(_ px: Double) -> Double { px * 0.75 }
static func pointsToPx(_ points: Double) -> Double { (points / 0.75).rounded() }

    // MARK: - Colours

    /// A CSS colour as `#rrggbb`, or nil for one this cannot read.
static func normalizeColor(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") {
            let body = String(raw.dropFirst()).lowercased()
            guard body.allSatisfy({ $0.isHexDigit }) else { return nil }
            if body.count == 6 { return "#\(body)" }
            if body.count == 3 { return "#" + body.map { "\($0)\($0)" }.joined() }
            return nil
        }
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"),
              raw.lowercased().hasPrefix("rgb") else { return nil }
        let parts = raw[raw.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        var hex = "#"
        for part in parts.prefix(3) {
            guard let value = Double(part) else { return nil }
            hex += String(format: "%02x", min(255, max(0, Int(value))))
        }
        return hex
    }

    /// `#rrggbb` as the `FFRRGGBB` an OOXML `rgb` attribute wants.
static func toArgb(_ value: String?) -> String? {
        guard let hex = normalizeColor(value) else { return nil }
        return "FF" + hex.dropFirst().uppercased()
    }

    /// An OOXML `rgb` attribute as `#rrggbb`, dropping the alpha byte.
static func fromArgb(_ value: String?) -> String? {
        guard let value else { return nil }
        let hex = value.count == 8 ? String(value.dropFirst(2)) : value
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#\(hex.lowercased())"
    }

    // MARK: - Number formats

    /// Built-in format ids worth reusing, so a plain file does not carry a `numFmts`.
static let builtinFormats: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
        9: "0%", 10: "0.00%", 14: "m/d/yyyy", 22: "m/d/yy h:mm",
    ]

    /// Where custom format codes start; below this the ids are Excel's own.
static let firstCustomFormatID = 164

    /// The format code for a structured `numberFormat` + `decimalPlaces`.
static func formatCode(numberFormat: String?, decimalPlaces: Int?,
                                  customFormat: String?) -> String? {
        if let customFormat, !customFormat.isEmpty { return customFormat }
        guard let kind = numberFormat, !kind.isEmpty else { return nil }
        let decimals = decimalPlaces ?? (kind == "currency" ? 2 : 0)
        let frac = decimals > 0 ? "." + String(repeating: "0", count: decimals) : ""
        switch kind {
        case "number":   return "#,##0\(frac)"
        case "currency": return "$#,##0\(frac)"
        case "percent":  return "0\(frac)%"
        case "date":     return "m/d/yyyy"
        case "time":     return "h:mm:ss AM/PM"
        case "datetime": return "m/d/yyyy h:mm:ss AM/PM"
        default:         return nil
        }
    }

    /// A format code back as `numberFormat` + `decimalPlaces`, when it is one of ours; nil for
    /// anything else, which becomes a `customFormat` instead.
    ///
    /// Exact matching, deliberately: a code this half-recognised would come back as a structured
    /// format that renders differently from the file, which is worse than carrying it through
    /// verbatim as a custom one.
static func structuredFormat(_ code: String) -> (kind: String, decimals: Int?)? {
        switch code {
        case "m/d/yyyy":                 return ("date", nil)
        case "h:mm:ss AM/PM":            return ("time", nil)
        case "m/d/yyyy h:mm:ss AM/PM":   return ("datetime", nil)
        default: break
        }
        if let decimals = decimals(of: code, prefix: "#,##0", suffix: "") {
            return ("number", decimals)
        }
        if let decimals = decimals(of: code, prefix: "$#,##0", suffix: "") {
            return ("currency", decimals)
        }
        if let decimals = decimals(of: code, prefix: "0", suffix: "%") {
            return ("percent", decimals)
        }
        return nil
    }

    /// The decimal count of `prefix` + optional `.000…` + `suffix`, or nil when the code is not
    /// that shape at all.
    private static func decimals(of code: String, prefix: String, suffix: String) -> Int? {
        guard code.hasPrefix(prefix), code.hasSuffix(suffix),
              code.count >= prefix.count + suffix.count else { return nil }
        let middle = String(code.dropFirst(prefix.count).dropLast(suffix.count))
        if middle.isEmpty { return 0 }
        guard middle.hasPrefix("."), middle.count > 1,
              middle.dropFirst().allSatisfy({ $0 == "0" }) else { return nil }
        return middle.count - 1
    }

    // MARK: - Alignment and borders

static let horizontalAlign: [String: String] = [
        "left": "left", "center": "center", "right": "right",
    ]
static let horizontalAlignBack: [String: String] = [
        "left": "left", "center": "center", "right": "right",
    ]
static let verticalAlign: [String: String] = [
        "top": "top", "middle": "center", "bottom": "bottom",
    ]
static let verticalAlignBack: [String: String] = [
        "top": "top", "center": "middle", "bottom": "bottom",
    ]

    /// The four sides in the model's spelling, paired with OOXML's element name, in the order the
    /// schema wants them written.
static let borderSides: [(key: String, tag: String)] = [
        ("borderLeft", "left"), ("borderRight", "right"),
        ("borderTop", "top"), ("borderBottom", "bottom"),
    ]

    /// OOXML's border style names happen to match the editor's for all three weights.
static func borderStyleName(_ weight: String?) -> String? {
        guard let weight, weight != "none",
              ["thin", "medium", "thick"].contains(weight) else { return nil }
        return weight
    }

static func borderWeight(_ name: String?) -> String? {
        guard let name, ["thin", "medium", "thick"].contains(name) else { return nil }
        return name
    }

    // MARK: - Conditional formats

    /// `cellIs` operators, both ways.
static let cfOperator: [String: String] = [
        "greaterThan": "greaterThan", "lessThan": "lessThan", "equalTo": "equal",
        "notEqualTo": "notEqual", "between": "between",
    ]
static let cfOperatorBack: [String: String] = [
        "greaterThan": "greaterThan", "lessThan": "lessThan", "equal": "equalTo",
        "notEqual": "notEqualTo", "between": "between",
    ]

    /// `timePeriod` values for the date conditions that have one.
static let cfTimePeriod: [String: String] = [
        "dateIsToday": "today", "dateIsTomorrow": "tomorrow",
        "dateIsNextWeek": "nextWeek", "dateIsThisMonth": "thisMonth",
    ]
static let cfTimePeriodBack: [String: String] = [
        "today": "dateIsToday", "tomorrow": "dateIsTomorrow",
        "nextWeek": "dateIsNextWeek", "thisMonth": "dateIsThisMonth",
    ]

    /// The three icon sets the editor offers, as OOXML's names for them.
static let cfIconSet: [String: String] = [
        "trafficLights": "3TrafficLights1", "arrows": "3Arrows", "ratings": "3Stars",
    ]
static let cfIconSetBack: [String: String] = [
        "3TrafficLights1": "trafficLights", "3Arrows": "arrows", "3Stars": "ratings",
    ]

    /// The colours a `themeColor` rule's token stands for.
static let cfThemeColors: [String: (background: String, color: String)] = [
        "success": ("#d7f5dd", "#0b6b2e"),
        "warning": ("#fff4cc", "#7a5300"),
        "danger":  ("#ffdcdc", "#8a1414"),
        "info":    ("#dbe9ff", "#123a7a"),
    ]

    /// The colour ramps a `heatMap` preset stands for, low → mid → high.
static let cfHeatMapPresets: [String: [String]] = [
        "financial":   ["#f8696b", "#ffeb84", "#63be7b"],
        "performance": ["#5a8ac6", "#fcfcff", "#f8696b"],
        "temperature": ["#4a7ebb", "#ffffff", "#e0574a"],
    ]

    private static let nativeCFKinds: Set<String> = [
        "singleColor", "colorScale", "dataBar", "iconSet",
        "duplicates", "uniques", "topBottom", "average", "formula",
    ]

    /// Whether a rule needs an entry in the extras part to come back exactly.
    ///
    /// True for a kind OOXML has no operator for, and for the one *condition* that has none either:
    /// `dateIsPastDue` is "before today", which is written as the comparison it is and would
    /// otherwise read back as an ordinary `lessThan`.
static func needsCFExtra(kind: String, condition: String?) -> Bool {
        if !nativeCFKinds.contains(kind) { return true }
        return kind == "singleColor" && condition == "dateIsPastDue"
    }

    // MARK: - Tab names

    private static let invalidInTabName: Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]
    private static let maxTabName = 31

    /// Tab names a workbook will accept.
    ///
    /// Excel rejects a name that is empty, over 31 characters, duplicated, wrapped in apostrophes or
    /// holding one of `[]:*?/\` — and a sheet is named by whoever made it, here or in the file this
    /// came from. Repairing is the only option that keeps the spreadsheet: refusing would fail the
    /// save.
static func tabNames(_ names: [String?]) -> [String] {
        var used = Set<String>()
        return names.enumerated().map { index, raw in
            var cleaned = String((raw ?? "").map { invalidInTabName.contains($0) ? " " : $0 })
            while cleaned.hasPrefix("'") { cleaned.removeFirst() }
            while cleaned.hasSuffix("'") { cleaned.removeLast() }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            cleaned = String(cleaned.prefix(maxTabName)).trimmingCharacters(in: .whitespaces)
            let base = cleaned.isEmpty ? "Sheet\(index + 1)" : cleaned
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                let suffix = " (\(n))"
                name = String(base.prefix(maxTabName - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    // MARK: - XML text

static let xmlDeclaration =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    /// Escape text for an element body or a double-quoted attribute, dropping the characters XML 1.0
    /// cannot carry at all.
    ///
    /// A cell can hold anything the user pasted, control characters included, and a workbook
    /// containing one is rejected outright rather than degraded — so a stray `\0` from a bad paste
    /// would cost the whole spreadsheet.
static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "\u{09}", "\u{0A}", "\u{0D}": out.unicodeScalars.append(scalar)
            case let other where other.value < 0x20: continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A number as OOXML writes it: integral values without a fractional part, so a width of 80
    /// is `80` and not `80.0`.
static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return String(Int(value)) }
        return String(value)
    }

    /// A width, which OOXML writes to four decimal places.
static func width(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
