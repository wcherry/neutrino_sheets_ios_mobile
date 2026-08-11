import UIKit

// MARK: - GridStyleResolver

/// Turns a ``CellStyle`` — which is CSS, because the format was designed for a browser — into the
/// UIKit values the renderer draws with.
///
/// Everything here is memoised. A screenful of a dense workbook is a few hundred cells, most of
/// them sharing a handful of styles, and parsing `"#1f2937"` or building a `UIFont` per cell per
/// frame is the difference between a grid that scrolls at 60fps and one that does not.
@MainActor
enum GridStyleResolver {

    // MARK: - Colours

    /// Parses a CSS colour: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(…)`, `rgba(…)`, or one of the
    /// named colours the web app's palette actually emits.
    ///
    /// Returns nil for anything unrecognised, which the renderer reads as "use the default" — a
    /// cell with an unparseable colour should look plain, not invisible.
    static func color(_ css: String?) -> UIColor? {
        guard let css else { return nil }
        let key = css.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, key != "none", key != "transparent", key != "inherit" else { return nil }
        if let cached = colorCache[key] { return cached }
        let parsed = parseColor(key)
        colorCache[key] = parsed
        return parsed
    }

    private static var colorCache: [String: UIColor?] = [:]

    private static func parseColor(_ key: String) -> UIColor? {
        if key.hasPrefix("#") { return hexColor(String(key.dropFirst())) }
        if key.hasPrefix("rgb") { return functionalColor(key) }
        return namedColors[key]
    }

    private static func hexColor(_ digits: String) -> UIColor? {
        let characters = Array(digits)
        // `#rgb` and `#rgba` are shorthand for doubled digits.
        let expanded: [Character]
        switch characters.count {
        case 3, 4: expanded = characters.flatMap { [$0, $0] }
        case 6, 8: expanded = characters
        default:   return nil
        }
        var components: [CGFloat] = []
        for pair in stride(from: 0, to: expanded.count, by: 2) {
            guard let value = UInt8(String(expanded[pair...pair + 1]), radix: 16) else { return nil }
            components.append(CGFloat(value) / 255)
        }
        return UIColor(red: components[0], green: components[1], blue: components[2],
                       alpha: components.count == 4 ? components[3] : 1)
    }

    private static func functionalColor(_ css: String) -> UIColor? {
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let parts = css[css.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        // The alpha component is 0…1; the colour components are 0…255.
        return UIColor(red: CGFloat(parts[0]) / 255, green: CGFloat(parts[1]) / 255,
                       blue: CGFloat(parts[2]) / 255,
                       alpha: parts.count >= 4 ? CGFloat(parts[3]) : 1)
    }

    /// The named colours the web app's own pickers can produce. Not the full CSS list — an
    /// exhaustive table would be 148 entries of which the app emits perhaps eight.
    private static let namedColors: [String: UIColor] = [
        "black": .black, "white": .white, "red": .systemRed, "green": .systemGreen,
        "blue": .systemBlue, "yellow": .systemYellow, "orange": .systemOrange,
        "purple": .systemPurple, "gray": .systemGray, "grey": .systemGray,
    ]

    // MARK: - Fonts

    /// The font for a cell, honouring family, size, weight and slant.
    ///
    /// Falls back to the system face for any family the device does not have. The web app's default
    /// stack is Inter/system-ui, which on iOS *is* the system face, so the common case is a plain
    /// system font and the fallback is not a compromise.
    static func font(for style: CellStyle?, defaultSize: CGFloat) -> UIFont {
        let size = style?.pointSize ?? defaultSize
        let key = FontKey(family: style?.fontFamily, size: size,
                          bold: style?.isBold ?? false, italic: style?.isItalic ?? false)
        if let cached = fontCache[key] { return cached }

        var font = customFont(named: key.family, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: key.bold ? .semibold : .regular)
        var traits: UIFontDescriptor.SymbolicTraits = []
        // A custom face needs its traits applied by descriptor; the system face already carries
        // its weight from `systemFont(ofSize:weight:)`.
        if key.bold, customFont(named: key.family, size: size) != nil { traits.insert(.traitBold) }
        if key.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        fontCache[key] = font
        return font
    }

    /// Resolves the first family in a CSS font stack that the device actually has.
    private static func customFont(named family: String?, size: CGFloat) -> UIFont? {
        guard let family else { return nil }
        for candidate in family.split(separator: ",") {
            let name = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            guard !name.isEmpty else { continue }
            // These are the CSS generics and the system stack; they mean "the system face", which
            // is the fallback anyway.
            let lower = name.lowercased()
            if ["inter", "system-ui", "-apple-system", "sans-serif", "serif", "monospace",
                "ui-sans-serif", "arial", "helvetica"].contains(lower) { return nil }
            if let font = UIFont(name: name, size: size) { return font }
        }
        return nil
    }

    private struct FontKey: Hashable {
        let family: String?
        let size: CGFloat
        let bold: Bool
        let italic: Bool
    }

    private static var fontCache: [FontKey: UIFont] = [:]

    // MARK: - Alignment

    static func alignment(_ style: CellStyle?, isNumeric: Bool) -> NSTextAlignment {
        switch style?.textAlign {
        case "center": return .center
        case "right":  return .right
        case "left":   return .left
        default:
            // The spreadsheet convention, and what the web app's CSS does by default: numbers sit
            // right, text sits left. Getting this wrong makes a column of figures unreadable.
            return isNumeric ? .right : .left
        }
    }

    /// Where the text sits within a cell taller than one line.
    static func verticalAlignment(_ style: CellStyle?) -> VerticalAlignment {
        switch style?.verticalAlign {
        case "top":    return .top
        case "bottom": return .bottom
        default:       return .middle
        }
    }

    enum VerticalAlignment { case top, middle, bottom }

    /// How text that does not fit its cell behaves.
    ///
    /// `overflow` — the web app's default — lets text spill into the neighbouring cell when that
    /// cell is empty, which is the behaviour every spreadsheet has.
    static func wrapMode(_ style: CellStyle?) -> WrapMode {
        switch style?.wrapMode {
        case "wrap": return .wrap
        case "clip": return .clip
        default:     return .overflow
        }
    }

    enum WrapMode { case overflow, wrap, clip }

    // MARK: - Borders

    /// The stroke width for a border weight, in points. `nil` means no border.
    static func borderWidth(_ weight: String?) -> CGFloat? {
        switch weight {
        case "thin":   return 1
        case "medium": return 2
        case "thick":  return 3
        default:       return nil
        }
    }

    // MARK: - Cache lifetime

    /// Drops the memo tables. Called on a memory warning — every entry is reconstructible, and a
    /// workbook with hundreds of distinct styles is the case where the caches are worth the most
    /// and cost the most.
    static func flushCaches() {
        colorCache.removeAll(keepingCapacity: true)
        fontCache.removeAll(keepingCapacity: true)
    }
}
