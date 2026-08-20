import Foundation

// MARK: - NumberFormats

/// Epic 9 — "Number formats and the custom-format dialog".
///
/// The preset table and the rule that turns a chosen pattern into a style patch are ported from
/// `editor/CustomFormatDialog.tsx`. Both halves matter: the *patterns* have to match because
/// ``CellFormatter`` renders them, and the *patch rule* has to match because a pattern picked here
/// must leave the same three keys behind that the browser's dialog would.
enum NumberFormats {

    // MARK: - Categories

    enum Category: String, CaseIterable, Identifiable {
        case number, currency, percent, datetime

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .number:   return "Number"
            case .currency: return "Currency"
            case .percent:  return "Percent"
            case .datetime: return "Date & Time"
            }
        }

        /// The value previewed under this category, matching the dialog's samples.
        var sample: String {
            self == .datetime ? "2025-11-01T13:30:00Z" : "1234.5678"
        }

        /// Which tab a cell's existing format belongs to. `date` and `time` were separate formats
        /// before the web app merged them, and cells written then still carry them.
        static func forNumberFormat(_ format: String?) -> Category {
            switch format {
            case "date", "time", "datetime": return .datetime
            case "currency":                 return .currency
            case "percent":                  return .percent
            default:                         return .number
            }
        }
    }

    // MARK: - Presets

    struct Preset: Hashable, Identifiable {
        /// What the pattern produces, e.g. `"1,234.00"`.
        let label: String
        let customFormat: String
        let numberFormat: String
        let decimalPlaces: Int?

        var id: String { customFormat }
    }

    static let presets: [Category: [Preset]] = [
        .number: [
            Preset(label: "1,234", customFormat: "#,##0", numberFormat: "number", decimalPlaces: 0),
            Preset(label: "1,234.0", customFormat: "#,##0.0", numberFormat: "number", decimalPlaces: 1),
            Preset(label: "1,234.00", customFormat: "#,##0.00", numberFormat: "number", decimalPlaces: 2),
            Preset(label: "1,234.000", customFormat: "#,##0.000", numberFormat: "number", decimalPlaces: 3),
            Preset(label: "1,234.0000", customFormat: "#,##0.0000", numberFormat: "number", decimalPlaces: 4),
            Preset(label: "1234", customFormat: "0", numberFormat: "number", decimalPlaces: 0),
            Preset(label: "1234.00", customFormat: "0.00", numberFormat: "number", decimalPlaces: 2),
        ],
        .currency: [
            Preset(label: "$1,234.00", customFormat: "\"$\"#,##0.00", numberFormat: "currency", decimalPlaces: 2),
            Preset(label: "$1,234", customFormat: "\"$\"#,##0", numberFormat: "currency", decimalPlaces: 0),
            Preset(label: "$1,234.0", customFormat: "\"$\"#,##0.0", numberFormat: "currency", decimalPlaces: 1),
            Preset(label: "$1,234.000", customFormat: "\"$\"#,##0.000", numberFormat: "currency", decimalPlaces: 3),
            Preset(label: "$1,234.0000", customFormat: "\"$\"#,##0.0000", numberFormat: "currency", decimalPlaces: 4),
        ],
        .percent: [
            Preset(label: "75%", customFormat: "0%", numberFormat: "percent", decimalPlaces: 0),
            Preset(label: "75.0%", customFormat: "0.0%", numberFormat: "percent", decimalPlaces: 1),
            Preset(label: "75.00%", customFormat: "0.00%", numberFormat: "percent", decimalPlaces: 2),
            Preset(label: "75.000%", customFormat: "0.000%", numberFormat: "percent", decimalPlaces: 3),
        ],
        .datetime: [
            Preset(label: "11/1/2025", customFormat: "M/D/yyyy", numberFormat: "date", decimalPlaces: nil),
            Preset(label: "11/01/2025", customFormat: "MM/DD/yyyy", numberFormat: "date", decimalPlaces: nil),
            Preset(label: "Nov 2025", customFormat: "mmm yyyy", numberFormat: "date", decimalPlaces: nil),
            Preset(label: "November 1, 2025", customFormat: "mmmm D, yyyy", numberFormat: "date", decimalPlaces: nil),
            Preset(label: "1-Nov-25", customFormat: "D-mmm-yy", numberFormat: "date", decimalPlaces: nil),
            Preset(label: "Sat, 1 Nov 2025", customFormat: "ddd, D mmm yyyy", numberFormat: "date", decimalPlaces: nil),
            Preset(label: "Saturday, 1 Nov 2025", customFormat: "dddd, D mmm yyyy", numberFormat: "date", decimalPlaces: nil),
            Preset(label: "1:30 PM", customFormat: "h:mm AM/PM", numberFormat: "time", decimalPlaces: nil),
            Preset(label: "1:30:00 PM", customFormat: "h:mm:ss AM/PM", numberFormat: "time", decimalPlaces: nil),
            Preset(label: "13:30", customFormat: "hh:mm", numberFormat: "time", decimalPlaces: nil),
            Preset(label: "13:30:00", customFormat: "hh:mm:ss", numberFormat: "time", decimalPlaces: nil),
            Preset(label: "11/1/2025 1:30 PM", customFormat: "M/D/yyyy h:mm AM/PM", numberFormat: "datetime", decimalPlaces: nil),
            Preset(label: "11/1/2025 13:30", customFormat: "M/D/yyyy hh:mm", numberFormat: "datetime", decimalPlaces: nil),
            Preset(label: "November 1, 2025 1:30 PM", customFormat: "mmmm D, yyyy h:mm AM/PM", numberFormat: "datetime", decimalPlaces: nil),
        ],
    ]

    static func presets(for category: Category) -> [Preset] {
        presets[category] ?? []
    }

    /// Every preset across every category, which is the set the dialog matches a typed pattern
    /// against.
    static var allPresets: [Preset] {
        Category.allCases.flatMap { presets(for: $0) }
    }

    // MARK: - Applying

    /// The patch the custom-format dialog's Apply button produces — the web app's `handleApply`.
    ///
    /// Three keys are always written, and two of them can be a *clear*:
    ///
    /// - `numberFormat` comes from the matching preset, falling back to the open category, so a
    ///   hand-typed `"mmm yyyy"` under Date & Time is still stored as a date;
    /// - `decimalPlaces` is the preset's or nothing at all, because a pattern already carries its
    ///   own decimal count and a stale `decimalPlaces` left behind by an earlier format would be
    ///   read by anything that falls back from `customFormat` to the preset formats;
    /// - `customFormat` is the pattern, or cleared when the field was emptied — which is how the
    ///   dialog is used to go back to a plain preset format.
    static func patch(forPattern pattern: String, category: Category) -> CellStylePatch {
        let match = allPresets.first { $0.customFormat == pattern }
        return CellStylePatch(
            numberFormat: .set(match?.numberFormat ?? category.rawValue),
            decimalPlaces: StyleUpdate(match?.decimalPlaces),
            customFormat: StyleUpdate(pattern.isEmpty ? nil : pattern)
        )
    }

    /// How a pattern renders its category's sample value, for the dialog's live preview. Returns
    /// the sample unchanged for an empty pattern, matching the dialog.
    static func preview(pattern: String, category: Category) -> String {
        guard !pattern.isEmpty else { return category.sample }
        return CellFormatter.applyCustomFormat(category.sample, pattern: pattern)
    }

    // MARK: - Quick formats

    /// The toolbar's one-tap formats. Tapping the one a cell already has removes it, which is how
    /// the web app's toggle buttons behave.
    static let quickFormats: [(id: String, label: String, accessibilityLabel: String)] = [
        ("currency", "$", "Currency"),
        ("percent", "%", "Percent"),
        ("number", "#", "Number"),
    ]
}
