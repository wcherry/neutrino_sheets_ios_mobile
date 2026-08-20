import Foundation

// MARK: - TableStyle

/// One entry in the table-style gallery, ported from `editor/styles/tableStyles.ts`.
///
/// The ids matter and are not cosmetic: a `TableStyle.id` is written into every ``TableRegion``
/// stored in a workbook, so a style whose id differs from the web app's is a region the web app
/// cannot resolve. The generated ids — hue, layout variant and border variant — are reproduced
/// exactly, including the deliberate empty suffix on the uniform border variant that keeps
/// `blue-banded` spelled the way saved files already spell it.
struct TableStyle: Hashable, Identifiable {

    let id: String
    let name: String
    let kind: Kind

    enum Kind: Hashable {
        case regular(Regular)
        /// The gallery's "Blank" entry: strips formatting and forgets the region.
        case blank
    }

    /// The colours and layout of a banded table.
    struct Regular: Hashable {
        let headerBackground: String
        let headerColor: String
        /// The band an even body row gets. Always white in the web app's palette.
        let bandColorA: String
        let bandColorB: String
        let border: BorderPatch
        let headerRow: Bool
        let headerColumn: Bool
        let totalRow: Bool
    }

    /// The five border keys a style writes, as a patch so the "leave alone" case is expressible.
    struct BorderPatch: Hashable {
        var borderStyle: StyleUpdate<String>
        var borderTop: StyleUpdate<String>
        var borderRight: StyleUpdate<String>
        var borderBottom: StyleUpdate<String>
        var borderLeft: StyleUpdate<String>

        /// Writes these five keys into a patch, leaving its other fields alone.
        func applied(to patch: CellStylePatch) -> CellStylePatch {
            var patch = patch
            patch.borderStyle = borderStyle
            patch.borderTop = borderTop
            patch.borderRight = borderRight
            patch.borderBottom = borderBottom
            patch.borderLeft = borderLeft
            return patch
        }
    }

    var regular: Regular? {
        if case .regular(let value) = kind { return value }
        return nil
    }
}

// MARK: - TableStyles

/// The gallery: fourteen hues × two layouts × three border treatments, plus Blank.
enum TableStyles {

    // MARK: - Palette

    /// Header background and body tint per hue. `bandColorA` is always white and header text is
    /// always white, exactly as in `tableStyles.ts`.
    private static let palette: [(hue: String, headerBackground: String, tint: String)] = [
        ("Blue", "#1e40af", "#dbeafe"),
        ("Sky", "#0369a1", "#e0f2fe"),
        ("Cyan", "#0e7490", "#cffafe"),
        ("Teal", "#0f766e", "#ccfbf1"),
        ("Emerald", "#047857", "#d1fae5"),
        ("Green", "#15803d", "#dcfce7"),
        ("Lime", "#4d7c0f", "#ecfccb"),
        ("Amber", "#b45309", "#fef3c7"),
        ("Orange", "#c2410c", "#ffedd5"),
        ("Red", "#b91c1c", "#fee2e2"),
        ("Rose", "#be123c", "#ffe4e6"),
        ("Purple", "#6d28d9", "#ede9fe"),
        ("Indigo", "#4338ca", "#e0e7ff"),
        ("Slate", "#334155", "#f1f5f9"),
    ]

    private static let layouts: [(slug: String, label: String,
                                  headerRow: Bool, headerColumn: Bool, totalRow: Bool)] = [
        ("banded", "Banded", true, false, false),
        ("header-totals", "Header & Totals", true, true, true),
    ]

    // MARK: - Border variants

    /// A single all-sides weight and no per-side keys.
    static let uniformBorder = TableStyle.BorderPatch(
        borderStyle: .set("thin"), borderTop: .clear, borderRight: .clear,
        borderBottom: .clear, borderLeft: .clear
    )

    static let noBorder = TableStyle.BorderPatch(
        borderStyle: .set("none"), borderTop: .set("none"), borderRight: .set("none"),
        borderBottom: .set("none"), borderLeft: .set("none")
    )

    static let horizontalBorder = TableStyle.BorderPatch(
        borderStyle: .set("none"), borderTop: .set("thin"), borderRight: .set("none"),
        borderBottom: .set("thin"), borderLeft: .set("none")
    )

    /// The uniform variant keeps empty suffixes so its ids and names are the ones already written
    /// into saved workbooks. Suffixed variants come first for the same reason the web app orders
    /// them that way — a fixed index then points at an unambiguous name.
    private static let borderVariants: [(idSuffix: String, nameSuffix: String,
                                         patch: TableStyle.BorderPatch)] = [
        ("-no-border", " \u{2014} No Border", noBorder),
        ("-horizontal", " \u{2014} Horizontal Lines", horizontalBorder),
        ("", "", uniformBorder),
    ]

    // MARK: - The gallery

    /// Every style, in the web app's order, with Blank last.
    static let all: [TableStyle] = {
        var styles: [TableStyle] = palette.flatMap { hue in
            layouts.flatMap { layout in
                borderVariants.map { border in
                    TableStyle(
                        id: "\(hue.hue.lowercased())-\(layout.slug)\(border.idSuffix)",
                        name: "\(hue.hue) \(layout.label)\(border.nameSuffix)",
                        kind: .regular(TableStyle.Regular(
                            headerBackground: hue.headerBackground,
                            headerColor: "#ffffff",
                            bandColorA: "#ffffff",
                            bandColorB: hue.tint,
                            border: border.patch,
                            headerRow: layout.headerRow,
                            headerColumn: layout.headerColumn,
                            totalRow: layout.totalRow
                        ))
                    )
                }
            }
        }
        styles.append(TableStyle(id: "blank", name: "Blank", kind: .blank))
        return styles
    }()

    static func style(withID id: String) -> TableStyle? {
        all.first { $0.id == id }
    }

    // MARK: - Applying

    /// The per-cell patches a regular style produces over `range` — a port of
    /// `computeTableStylePatches`.
    ///
    /// Banding is counted from the first *body* row, not from the top of the range, so a table with
    /// a header row starts its first band immediately under it rather than inheriting the header's
    /// parity.
    static func patches(for style: TableStyle.Regular, in range: CellRange) -> [String: CellStylePatch] {
        let headerPatch = style.border.applied(to: CellStylePatch(
            fontWeight: .set("bold"),
            color: .set(style.headerColor),
            backgroundColor: .set(style.headerBackground)
        ))

        let headerOffset = style.headerRow ? 1 : 0
        var patches: [String: CellStylePatch] = [:]

        for address in range.addresses {
            let bodyRowIndex = address.row - range.start.row - headerOffset
            // Swift's `%` keeps the sign of the dividend, so the header row of a header-row table
            // lands on -1 and would band as "odd". It is overwritten by the header patch below,
            // but the parity is normalised anyway so the two clients agree cell for cell.
            let isBandA = ((bodyRowIndex % 2) + 2) % 2 == 0
            var patch = style.border.applied(to: CellStylePatch(
                fontWeight: .set("normal"),
                // Cleared, not left alone: a body cell that used to be a header must lose the
                // header's white text or it becomes invisible on a white band.
                color: .clear,
                backgroundColor: .set(isBandA ? style.bandColorA : style.bandColorB)
            ))

            if style.headerColumn, address.column == range.start.column { patch = headerPatch }
            if style.headerRow, address.row == range.start.row { patch = headerPatch }
            if style.totalRow, address.row == range.end.row, range.end.row > range.start.row {
                patch = headerPatch
            }

            patches[address.id] = patch
        }
        return patches
    }
}
