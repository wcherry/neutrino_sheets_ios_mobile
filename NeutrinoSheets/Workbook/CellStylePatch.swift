import Foundation

// MARK: - StyleUpdate

/// What a patch does to one field: leave it, give it a value, or take it away.
///
/// The third case is the reason this type exists. The web app patches a style with
/// `{...cell.cellStyle, ...patch}`, where a key present-but-`undefined` **erases** the old value —
/// that is exactly how its "Clear formatting" and its Blank table style work. Swift's `nil` cannot
/// express the difference between "not in the patch" and "remove this", so a plain
/// `CellStyle` of optionals would silently turn every clear into a no-op.
enum StyleUpdate<Value: Hashable>: Hashable {

    /// Not part of this patch; whatever the cell already had survives.
    case unchanged
    case set(Value)
    /// Removes the field, the way a `undefined` in the web app's spread does.
    case clear

    /// `.set` for a value and `.clear` for nil — the shape a picker with an "automatic" entry
    /// produces.
    init(_ value: Value?) {
        self = value.map { .set($0) } ?? .clear
    }

    /// The field's value after this update is applied to `current`.
    func resolve(_ current: Value?) -> Value? {
        switch self {
        case .unchanged:      return current
        case .set(let value): return value
        case .clear:          return nil
        }
    }

    var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

// MARK: - CellStylePatch

/// Epic 9 — a partial change to a cell's presentation, applied across a selection.
///
/// One patch describes every formatting command in the app: bolding is
/// `CellStylePatch(fontWeight: .set("bold"))`, clearing formatting is every field `.clear`, and a
/// table-style preset is one of these per cell. Keeping them all in one type is what lets the
/// editor route every formatting command through the same undo funnel as a typed value.
///
/// The field set and the values written are the web app's, down to the details that look like
/// mistakes: un-bolding writes `"normal"` rather than removing `fontWeight`, and the border
/// dropdown writes `borderStyle` *and* clears all four per-side keys, because a per-side value
/// would otherwise keep overriding the weight the user just chose.
struct CellStylePatch: Hashable {

    // MARK: - Text

    var fontFamily: StyleUpdate<String> = .unchanged
    var fontSize: StyleUpdate<String> = .unchanged
    var fontWeight: StyleUpdate<String> = .unchanged
    var fontStyle: StyleUpdate<String> = .unchanged
    var textDecoration: StyleUpdate<String> = .unchanged
    var color: StyleUpdate<String> = .unchanged
    var backgroundColor: StyleUpdate<String> = .unchanged

    // MARK: - Alignment

    var textAlign: StyleUpdate<String> = .unchanged
    var verticalAlign: StyleUpdate<String> = .unchanged
    var wrapMode: StyleUpdate<String> = .unchanged

    // MARK: - Borders

    var borderStyle: StyleUpdate<String> = .unchanged
    var borderTop: StyleUpdate<String> = .unchanged
    var borderRight: StyleUpdate<String> = .unchanged
    var borderBottom: StyleUpdate<String> = .unchanged
    var borderLeft: StyleUpdate<String> = .unchanged

    // MARK: - Numbers

    var numberFormat: StyleUpdate<String> = .unchanged
    var decimalPlaces: StyleUpdate<Int> = .unchanged
    var customFormat: StyleUpdate<String> = .unchanged

    // MARK: - Applying

    /// True when the patch would change nothing, so the caller can skip recording an edit.
    var isEmpty: Bool {
        fontFamily.isUnchanged && fontSize.isUnchanged && fontWeight.isUnchanged
            && fontStyle.isUnchanged && textDecoration.isUnchanged && color.isUnchanged
            && backgroundColor.isUnchanged && textAlign.isUnchanged && verticalAlign.isUnchanged
            && wrapMode.isUnchanged && borderStyle.isUnchanged && borderTop.isUnchanged
            && borderRight.isUnchanged && borderBottom.isUnchanged && borderLeft.isUnchanged
            && numberFormat.isUnchanged && decimalPlaces.isUnchanged && customFormat.isUnchanged
    }

    /// The style `style` becomes under this patch.
    ///
    /// Returns nil when nothing is left, so the cell drops its `cellStyle` key entirely rather than
    /// storing `{}` — matching what the web app writes, and what the round-trip fixtures assert.
    func applied(to style: CellStyle?) -> CellStyle? {
        var result = style ?? CellStyle()
        result.fontFamily = fontFamily.resolve(result.fontFamily)
        result.fontSize = fontSize.resolve(result.fontSize)
        result.fontWeight = fontWeight.resolve(result.fontWeight)
        result.fontStyle = fontStyle.resolve(result.fontStyle)
        result.textDecoration = textDecoration.resolve(result.textDecoration)
        result.color = color.resolve(result.color)
        result.backgroundColor = backgroundColor.resolve(result.backgroundColor)
        result.textAlign = textAlign.resolve(result.textAlign)
        result.verticalAlign = verticalAlign.resolve(result.verticalAlign)
        result.wrapMode = wrapMode.resolve(result.wrapMode)
        result.borderStyle = borderStyle.resolve(result.borderStyle)
        result.borderTop = borderTop.resolve(result.borderTop)
        result.borderRight = borderRight.resolve(result.borderRight)
        result.borderBottom = borderBottom.resolve(result.borderBottom)
        result.borderLeft = borderLeft.resolve(result.borderLeft)
        result.numberFormat = numberFormat.resolve(result.numberFormat)
        result.decimalPlaces = decimalPlaces.resolve(result.decimalPlaces)
        result.customFormat = customFormat.resolve(result.customFormat)
        return result.isEmpty ? nil : result
    }
}

// MARK: - CellStylePatch + Commands

/// One constructor per formatting command, so the views describe *what the user asked for* and this
/// file is the only place that knows what the web app writes for it.
extension CellStylePatch {

    // MARK: Text

    static func bold(_ on: Bool) -> Self {
        CellStylePatch(fontWeight: .set(on ? "bold" : "normal"))
    }

    static func italic(_ on: Bool) -> Self {
        CellStylePatch(fontStyle: .set(on ? "italic" : "normal"))
    }

    static func strikethrough(_ on: Bool) -> Self {
        CellStylePatch(textDecoration: .set(on ? "line-through" : "none"))
    }

    /// - Parameter family: a CSS font stack, or nil for the workbook default.
    static func fontFamily(_ family: String?) -> Self {
        CellStylePatch(fontFamily: StyleUpdate(family))
    }

    /// The web app's font-size dropdown writes points (`"14pt"`) and reads them back by stripping
    /// the suffix, so a size written any other way would show as blank in its own toolbar.
    static func fontSize(_ points: Int?) -> Self {
        CellStylePatch(fontSize: StyleUpdate(points.map { "\($0)pt" }))
    }

    static func textColor(_ css: String?) -> Self {
        CellStylePatch(color: StyleUpdate(css))
    }

    static func fillColor(_ css: String?) -> Self {
        CellStylePatch(backgroundColor: StyleUpdate(css))
    }

    // MARK: Alignment

    static func textAlign(_ value: String?) -> Self {
        CellStylePatch(textAlign: StyleUpdate(value))
    }

    static func verticalAlign(_ value: String?) -> Self {
        CellStylePatch(verticalAlign: StyleUpdate(value))
    }

    static func wrapMode(_ value: String?) -> Self {
        CellStylePatch(wrapMode: StyleUpdate(value))
    }

    // MARK: Borders

    /// All four sides at one weight — the web app's border dropdown.
    ///
    /// The per-side keys are cleared as well as `borderStyle` being set, because
    /// ``CellStyle/border(_:)`` reads a per-side value in preference to the all-sides one: leaving
    /// a stale `borderLeft: "thick"` behind would make the chosen weight not apply on that edge.
    static func allBorders(_ weight: String?) -> Self {
        CellStylePatch(borderStyle: .set(weight ?? "none"),
                       borderTop: .clear, borderRight: .clear,
                       borderBottom: .clear, borderLeft: .clear)
    }

    /// One edge, leaving the other three as they are.
    static func border(_ side: CellStyle.BorderSide, _ weight: String?) -> Self {
        let update = StyleUpdate<String>.set(weight ?? "none")
        switch side {
        case .top:    return CellStylePatch(borderTop: update)
        case .right:  return CellStylePatch(borderRight: update)
        case .bottom: return CellStylePatch(borderBottom: update)
        case .left:   return CellStylePatch(borderLeft: update)
        }
    }

    // MARK: Numbers

    /// A preset number format. Passing the format the cell already has is how the web app's
    /// toolbar toggles one off, so the caller decides; this only writes what it is given.
    static func numberFormat(_ value: String?) -> Self {
        CellStylePatch(numberFormat: StyleUpdate(value))
    }

    static func decimalPlaces(_ places: Int) -> Self {
        CellStylePatch(decimalPlaces: .set(max(0, places)))
    }

    // MARK: Clearing

    /// Every field removed — the web app's `BlankTableStyle.clearPatch`, and the "Clear formatting"
    /// command.
    static let clearFormatting = CellStylePatch(
        fontFamily: .clear, fontSize: .clear, fontWeight: .clear, fontStyle: .clear,
        textDecoration: .clear, color: .clear, backgroundColor: .clear,
        textAlign: .clear, verticalAlign: .clear, wrapMode: .clear,
        borderStyle: .clear, borderTop: .clear, borderRight: .clear,
        borderBottom: .clear, borderLeft: .clear,
        numberFormat: .clear, decimalPlaces: .clear, customFormat: .clear
    )
}

// MARK: - CellStyle + Emptiness

extension CellStyle {

    /// True when no field is set, i.e. the style is not worth storing.
    var isEmpty: Bool {
        self == CellStyle()
    }
}
