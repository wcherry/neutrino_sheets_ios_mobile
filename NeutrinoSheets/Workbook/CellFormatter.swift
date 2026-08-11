import Foundation

// MARK: - CellFormatter

/// Turns a cell's stored value into the text the grid draws.
///
/// A direct port of `formatCellValue` / `applyCustomFormat` and their helpers in
/// `web/apps/web/src/app/(apps)/sheets/editor/utils.ts`. The web app hard-codes the `en-US` locale
/// and the UTC time zone in every one of those calls, so this does too — a workbook must show the
/// same thing on a phone in Berlin as it does in the browser next to it, and following the device
/// locale here would silently make `1,234.50` into `1.234,50` on one device and not the other.
///
/// Everything is `static`: formatting depends only on its inputs, and the shared formatters below
/// are the only state.
enum CellFormatter {

    // MARK: - Entry point

    /// The display text for `value` under `style`.
    ///
    /// An empty value formats to empty, and a value that is not a number under a numeric format is
    /// returned unchanged — both matching the web app, which shows the user's text rather than
    /// `NaN` when a format does not apply.
    static func display(_ value: String?, style: CellStyle?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if let custom = style?.customFormat, !custom.isEmpty {
            return applyCustomFormat(value, pattern: custom)
        }
        guard let format = style?.numberFormat else { return value }

        switch format {
        case "currency", "percent", "number":
            guard let number = parseNumber(value) else { return value }
            // Currency defaults to 2 decimals, everything else to 0 — `style.decimalPlaces ??
            // (numberFormat === 'currency' ? 2 : 0)`.
            let decimals = style?.decimalPlaces ?? (format == "currency" ? 2 : 0)
            switch format {
            case "currency": return currency(number, decimals: decimals)
            case "percent":  return percent(number, decimals: decimals)
            default:         return decimal(number, decimals: decimals, grouping: true)
            }
        case "date", "time", "datetime":
            guard let date = parseCellDate(value) else { return value }
            switch format {
            case "date": return dateFormatter.string(from: date)
            case "time": return timeFormatter.string(from: date)
            default:     return dateTimeFormatter.string(from: date)
            }
        default:
            return value
        }
    }

    // MARK: - Numbers

    /// `parseFloat` semantics: leading numeric prefix wins, trailing junk is ignored, and a string
    /// that does not start with a number is not one.
    static func parseNumber(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var end = trimmed.startIndex
        var seenDigit = false
        var seenDot = false
        var seenExponent = false
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.isNumber {
                seenDigit = true
            } else if character == "." && !seenDot && !seenExponent {
                seenDot = true
            } else if (character == "e" || character == "E") && seenDigit && !seenExponent {
                seenExponent = true
                // An exponent's sign belongs to the exponent, not to a new number after it.
                let next = trimmed.index(after: index)
                if next < trimmed.endIndex, trimmed[next] == "+" || trimmed[next] == "-" {
                    index = next
                }
            } else if (character == "-" || character == "+") && index == trimmed.startIndex {
                // A leading sign only.
            } else {
                break
            }
            index = trimmed.index(after: index)
            end = index
        }
        guard seenDigit else { return nil }
        return Double(trimmed[..<end])
    }

    static func decimal(_ value: Double, decimals: Int, grouping: Bool) -> String {
        let formatter = numberFormatter
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func currency(_ value: Double, decimals: Int) -> String {
        let formatter = numberFormatter
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Note the ×100: `Intl.NumberFormat`'s percent style multiplies, so `0.25` shows as `25%`.
    /// `NumberFormatter.percent` does the same, and getting this wrong is a silent factor-of-100
    /// error rather than a visible one.
    static func percent(_ value: Double, decimals: Int) -> String {
        let formatter = numberFormatter
        formatter.numberStyle = .percent
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Dates

    /// Excel's day-serial epoch: serial 1 is 1 Jan 1900.
    ///
    /// Excel treats 1900 as a leap year — serial 60 is a 29 February that never happened — so every
    /// serial past 60 is one day ahead of the real calendar and has to be pulled back. The web app
    /// does the same, and matching its arithmetic exactly matters more than being right about 1900.
    static func date(fromExcelSerial serial: Double) -> Date {
        let adjusted = serial > 60 ? serial - 1 : serial
        // Rounded to the second. A time-of-day is stored as a fraction of a day, and 13:05:09 is
        // 47109/86400 — a value no binary float holds exactly, so multiplying back out lands a
        // hair under and truncates to :08. Off-by-one-second on every third timestamp, and
        // invisible until someone compares a cell against the browser.
        let seconds = (excelEpoch + (adjusted - 1) * 86_400).rounded()
        return Date(timeIntervalSince1970: seconds)
    }

    /// Inverse of ``date(fromExcelSerial:)``, re-adding the phantom 29 Feb 1900 so the round trip
    /// closes.
    static func excelSerial(from date: Date) -> Double {
        let days = ((date.timeIntervalSince1970 - excelEpoch) / 86_400).rounded()
        let adjusted = days + 1
        return adjusted > 59 ? adjusted + 1 : adjusted
    }

    /// 1 Jan 1900, 00:00 UTC as a Unix timestamp.
    private static let excelEpoch: TimeInterval = -2_208_988_800

    /// Parses a date, a time, or a date and time into an Excel serial — the web app's
    /// `dateStringToSerial`. Returns nil for anything that is not one of those shapes, letting the
    /// caller fall back to plain numeric parsing.
    ///
    /// Accepts `2026-01-01`, `01/01/2026`, `13:30`, `1:30 PM`, and either date form followed by
    /// either time form separated by a space or a `T`.
    static func serial(fromDateString value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var datePart = text
        var timePart: String?

        if let separator = splitPoint(in: text) {
            datePart = String(text[text.startIndex..<separator.lowerBound])
            timePart = String(text[separator.upperBound...])
        } else if let time = parseTimeParts(text) {
            // No separator: the whole string may be a bare time, which is a fraction of a day.
            return fraction(ofDay: time)
        }

        guard let day = parseDateParts(datePart) else { return nil }
        var serial = excelSerial(from: day)
        if let timePart {
            guard let time = parseTimeParts(timePart) else { return nil }
            serial += fraction(ofDay: time)
        }
        return serial
    }

    /// Parses a cell value as a date the way both the preset and custom formatters do: a bare
    /// number is an Excel serial, a recognised date/time string becomes one, and anything else is
    /// not a date. Returns nil where the web app produces an `Invalid Date`.
    static func parseCellDate(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if isPlainNumber(text), let number = Double(text) {
            return date(fromExcelSerial: number)
        }
        if let serial = serial(fromDateString: text) {
            return date(fromExcelSerial: serial)
        }
        // The web app's last resort is `new Date(value)`, which parses ISO-8601. Anything looser
        // than that is engine-specific in JavaScript and not worth reproducing.
        return isoFormatter.date(from: text)
    }

    // MARK: - Custom formats

    /// Applies an Excel-style pattern — the web app's `applyCustomFormat`.
    static func applyCustomFormat(_ value: String, pattern: String) -> String {
        if isDateOrTimePattern(pattern) {
            guard let date = parseCellDate(value) else { return value }
            return formatDate(date, pattern: pattern)
        }
        guard let number = parseNumber(value) else { return value }

        // Decimal count comes from the digits after the '.' in the pattern; grouping from a ','.
        let decimals = decimalPlaces(inPattern: pattern)
        if pattern.contains("%") {
            return percent(number, decimals: decimals)
        }
        if pattern.contains("$") {
            return currency(number, decimals: decimals)
        }
        return decimal(number, decimals: decimals, grouping: pattern.contains(","))
    }

    /// True when a pattern is a date/time pattern rather than a numeric one, ignoring quoted
    /// literals so `"Month"` in a number format does not look like a month token.
    static func isDateOrTimePattern(_ pattern: String) -> Bool {
        let withoutLiterals = removeQuotedLiterals(from: pattern)
        return withoutLiterals.contains { "dmyDMY".contains($0) }
            || withoutLiterals.lowercased().contains("h")
            || withoutLiterals.lowercased().contains("s")
    }

    /// Renders `date` through an Excel date pattern — the web app's `formatDateWithPattern`.
    ///
    /// The awkward part is `m`: it means *month* on its own and *minute* next to an hour or a
    /// seconds token. The tokens are therefore scanned first so each `m` can look at its
    /// neighbours, and only then substituted.
    static func formatDate(_ date: Date, pattern: String) -> String {
        var literals: [String] = []
        let masked = maskQuotedLiterals(in: pattern, into: &literals)

        let tokens = tokenize(masked)
        let hasMeridiem = tokens.contains {
            let lower = $0.text.lowercased()
            return lower == "am/pm" || lower == "a/p"
        }
        var minuteTokens = Set<Int>()
        for (index, token) in tokens.enumerated() {
            let lower = token.text.lowercased()
            guard lower == "m" || lower == "mm" else { continue }
            let previous = index > 0 ? tokens[index - 1].text.lowercased() : nil
            let next = index + 1 < tokens.count ? tokens[index + 1].text.lowercased() : nil
            if previous == "h" || previous == "hh" || next == "s" || next == "ss" {
                minuteTokens.insert(index)
            }
        }

        let parts = calendar.dateComponents(
            [.year, .month, .day, .weekday, .hour, .minute, .second], from: date
        )
        var result = ""
        var cursor = masked.startIndex
        for (index, token) in tokens.enumerated() {
            result += masked[cursor..<token.range.lowerBound]
            result += substitute(token.text, isMinute: minuteTokens.contains(index),
                                 hasMeridiem: hasMeridiem, parts: parts)
            cursor = token.range.upperBound
        }
        result += masked[cursor...]
        return restoreLiterals(in: result, from: literals)
    }

    // MARK: - Token substitution

    private static func substitute(_ token: String, isMinute: Bool, hasMeridiem: Bool,
                                   parts: DateComponents) -> String {
        let month = parts.month ?? 1
        let hour24 = parts.hour ?? 0
        let hour = hasMeridiem ? (hour24 % 12 == 0 ? 12 : hour24 % 12) : hour24

        switch token.lowercased() {
        case "mmmm": return monthNames[month - 1]
        case "mmm":  return monthAbbreviations[month - 1]
        case "mm":   return pad(isMinute ? (parts.minute ?? 0) : month)
        case "m":    return String(isMinute ? (parts.minute ?? 0) : month)
        case "dddd": return dayNames[(parts.weekday ?? 1) - 1]
        case "ddd":  return dayAbbreviations[(parts.weekday ?? 1) - 1]
        case "dd":   return pad(parts.day ?? 1)
        case "d":    return String(parts.day ?? 1)
        case "yyyy": return String(parts.year ?? 1900)
        case "yy":   return String(String(parts.year ?? 1900).suffix(2))
        case "hh":   return pad(hour)
        case "h":    return String(hour)
        case "ss":   return pad(parts.second ?? 0)
        case "s":    return String(parts.second ?? 0)
        case "am/pm":
            let lower = token == token.lowercased()
            return hour24 < 12 ? (lower ? "am" : "AM") : (lower ? "pm" : "PM")
        case "a/p":
            let lower = token == token.lowercased()
            return hour24 < 12 ? (lower ? "a" : "A") : (lower ? "p" : "P")
        default:
            return token
        }
    }

    /// The pattern's tokens, longest-first so `mmmm` is never read as two `mm`s.
    private static func tokenize(_ pattern: String) -> [(text: String, range: Range<String.Index>)] {
        let candidates = ["mmmm", "mmm", "dddd", "ddd", "am/pm", "a/p",
                          "yyyy", "yy", "mm", "dd", "hh", "ss", "m", "d", "h", "s"]
        var tokens: [(String, Range<String.Index>)] = []
        var index = pattern.startIndex
        outer: while index < pattern.endIndex {
            for candidate in candidates {
                guard let end = pattern.index(index, offsetBy: candidate.count,
                                              limitedBy: pattern.endIndex) else { continue }
                if pattern[index..<end].lowercased() == candidate {
                    tokens.append((String(pattern[index..<end]), index..<end))
                    index = end
                    continue outer
                }
            }
            index = pattern.index(after: index)
        }
        return tokens
    }

    // MARK: - Pattern helpers

    /// The number of digits after the `.` in a numeric pattern: `"#,##0.00"` is 2.
    private static func decimalPlaces(inPattern pattern: String) -> Int {
        guard let dot = pattern.firstIndex(of: ".") else { return 0 }
        return pattern[pattern.index(after: dot)...].prefix { $0 == "0" || $0 == "#" }.count
    }

    /// Replaces `"…"` runs with `\u{0}<index>\u{0}` so their contents are never token-matched.
    private static func maskQuotedLiterals(in pattern: String, into literals: inout [String]) -> String {
        var result = ""
        var inLiteral = false
        var current = ""
        for character in pattern {
            if character == "\"" {
                if inLiteral {
                    result += "\u{0}\(literals.count)\u{0}"
                    literals.append(current)
                    current = ""
                }
                inLiteral.toggle()
            } else if inLiteral {
                current.append(character)
            } else {
                result.append(character)
            }
        }
        // An unterminated quote takes the rest of the pattern with it, as the web app's regex does.
        if inLiteral { result += current }
        return result
    }

    private static func restoreLiterals(in text: String, from literals: [String]) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\u{0}",
                  let close = text[text.index(after: index)...].firstIndex(of: "\u{0}"),
                  let slot = Int(text[text.index(after: index)..<close]),
                  slot < literals.count else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            result += literals[slot]
            index = text.index(after: close)
        }
        return result
    }

    private static func removeQuotedLiterals(from pattern: String) -> String {
        var literals: [String] = []
        return maskQuotedLiterals(in: pattern, into: &literals)
    }

    // MARK: - Date parsing helpers

    /// Splits `"<date> <time>"` or `"<date>T<time>"` at the separator before the time.
    private static func splitPoint(in text: String) -> Range<String.Index>? {
        // Scanned from the right so an ISO date's own hyphens are never mistaken for the split.
        for index in text.indices.reversed() where text[index] == " " || text[index] == "T" {
            let after = text.index(after: index)
            guard after < text.endIndex else { continue }
            if parseTimeParts(String(text[after...])) != nil {
                return index..<after
            }
        }
        return nil
    }

    /// Parses `2026-01-01` or `01/01/2026` to UTC midnight, rejecting calendar overflow so
    /// `02/30/2026` does not silently roll into March.
    private static func parseDateParts(_ text: String) -> Date? {
        let isoParts = text.split(separator: "-", omittingEmptySubsequences: false)
        let usParts = text.split(separator: "/", omittingEmptySubsequences: false)

        var year = 0, month = 0, day = 0
        if isoParts.count == 3, isoParts[0].count == 4 {
            guard let y = Int(isoParts[0]), let m = Int(isoParts[1]), let d = Int(isoParts[2]) else {
                return nil
            }
            (year, month, day) = (y, m, d)
        } else if usParts.count == 3 {
            guard let m = Int(usParts[0]), let d = Int(usParts[1]), var y = Int(usParts[2]) else {
                return nil
            }
            // Two-digit years pivot at 50, matching the web app.
            if y < 100 { y += y < 50 ? 2000 : 1900 }
            (year, month, day) = (y, m, d)
        } else {
            return nil
        }

        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }

    /// Parses `13:30`, `13:30:00`, `1:30 PM`, `1:30:00 PM` into 24-hour parts.
    private static func parseTimeParts(_ text: String) -> (hour: Int, minute: Int, second: Int)? {
        var body = text.trimmingCharacters(in: .whitespaces)
        var meridiem: String?
        for suffix in ["AM", "PM", "am", "pm", "Am", "Pm", "aM", "pM"] where body.hasSuffix(suffix) {
            meridiem = suffix.lowercased()
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              var hour = Int(parts[0]), let minute = Int(parts[1]),
              parts[1].count == 2 else { return nil }
        let second = parts.count == 3 ? Int(parts[2]) : 0
        guard let second, minute <= 59, second <= 59 else { return nil }

        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = meridiem == "am" ? hour % 12 : (hour % 12) + 12
        } else if hour > 23 {
            return nil
        }
        return (hour, minute, second)
    }

    private static func fraction(ofDay time: (hour: Int, minute: Int, second: Int)) -> Double {
        Double(time.hour * 3600 + time.minute * 60 + time.second) / 86_400
    }

    /// `/^\d+(\.\d+)?$/` — a bare, unsigned decimal, which is how a stored Excel serial looks.
    private static func isPlainNumber(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isNumber || $0 == "." } && text.filter { $0 == "." }.count <= 1
            && text.first != "."
    }

    // MARK: - Shared formatters

    /// Formatter construction is expensive enough to show up on a scrolling grid, and these are
    /// stateless between calls once their style is set. Reused rather than rebuilt per cell.
    ///
    /// Not thread-safe, and deliberately so: every caller is the main-actor render path.
    ///
    /// `en_US`, not `en_US_POSIX`: the POSIX variant formats currency as `$ 1,250.50`, with a
    /// space, where `Intl.NumberFormat('en-US')` — and therefore the web app — writes `$1,250.50`.
    /// The locale is still fixed, so this remains independent of the device's own.
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        // `Intl.NumberFormat` rounds half away from zero; `NumberFormatter` defaults to banker's
        // rounding, which sends 1250.5 to 1250 where a browser shows 1251. Verified against
        // `toLocaleString('en-US')` for positives, negatives, and both parities of the tie.
        formatter.roundingMode = .halfUp
        return formatter
    }()

    /// `toLocaleDateString('en-US', { timeZone: 'UTC' })` — `8/10/2026`.
    private static let dateFormatter = makeDateFormatter("M/d/yyyy")
    /// `toLocaleTimeString('en-US', { timeZone: 'UTC' })` — `1:30:00 PM`.
    private static let timeFormatter = makeDateFormatter("h:mm:ss a")
    /// `toLocaleString('en-US', { timeZone: 'UTC' })` — `8/10/2026, 1:30:00 PM`.
    private static let dateTimeFormatter = makeDateFormatter("M/d/yyyy, h:mm:ss a")
    /// The `new Date(value)` fallback, narrowed to ISO-8601.
    private static let isoFormatter = makeDateFormatter("yyyy-MM-dd'T'HH:mm:ssXXXXX")

    private static func makeDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]
    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                             "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                   "Thursday", "Friday", "Saturday"]
    private static let dayAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}
