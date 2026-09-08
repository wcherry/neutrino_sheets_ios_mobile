import Foundation
import NeutrinoOOXML

// MARK: - XlsxReader

/// An `.xlsx` → the sheets editor's model.
///
/// The other half of ``XlsxWriter``, and the half that decides what "opening a spreadsheet" means.
/// It reads the parts directly: `workbook.xml` for the tabs and their order, `styles.xml` for the
/// format, font, fill, border and alignment each cell points at, the worksheet parts for cells,
/// formulas, merges, column widths, row heights, conditional formats and table regions, and the
/// custom XML part for the handful of things OOXML cannot say.
///
/// Anything it does not recognise is left behind rather than guessed at, and the cell keeps its
/// value: a workbook written by another tool is a workbook written by software that knows constructs
/// this does not, and losing a column of numbers is much worse than losing its shading.
///
/// ## Known gaps, shared with the web reader
///
/// Shared formulas (`<f t="shared">`) are read as their own text where the master carries it and as
/// empty where it does not — Excel writes the formula once and leaves the rest of the group to
/// derive it, and deriving it means translating relative references. Cells in that position keep
/// their cached value, so the spreadsheet reads correctly and re-saves as literals. Rich text runs
/// inside a shared string collapse to their concatenated text.
///
/// The Swift half of `web/apps/web/src/lib/ooxml/xlsx/read.ts`.
enum XlsxReader {

    // MARK: - Errors

    enum ReadError: Error {
        /// The package has no `xl/workbook.xml`, so it is not a workbook whatever else it is.
        case notAWorkbook
    }

    // MARK: - Entry point

    /// `data` as the stored `{"sheets":[…]}` envelope.
    static func read(_ data: Data) throws -> OOXMLValue {
        let zip = try ZipArchive(data: data)
        guard let workbookXML = zip.text(for: XlsxMapping.workbookPart),
              let workbook = XMLElement.parse(workbookXML) else {
            throw ReadError.notAWorkbook
        }

        let rels = relationships(in: zip, for: XlsxMapping.workbookPart)
        let styles = readStyles(zip)
        let shared = readSharedStrings(zip)
        let extras = readExtras(zip)

        var sheets: [OOXMLValue] = []
        for (index, entry) in workbook.descendants("sheet").enumerated() {
            let extra = extras["sheets"]?[String(index)]
            let name = entry.attribute("name") ?? "Sheet \(index + 1)"
            let path = entry.attribute("id", uri: OOXMLNamespace.r).flatMap { rels[$0] }
            guard let path, let sheetXML = zip.text(for: path),
                  let root = XMLElement.parse(sheetXML) else {
                // A tab whose part is missing or unreadable — a chart sheet, say — still has to
                // exist, or every tab after it shifts left.
                sheets.append(.object(["name": .string(name), "cells": .object([:])]))
                continue
            }
            sheets.append(readSheet(root, path: path, name: name, index: index, zip: zip,
                                    styles: styles, shared: shared, extra: extra))
        }

        if sheets.isEmpty {
            sheets = [.object(["name": .string("Sheet 1"), "cells": .object([:])])]
        }
        return .object(["sheets": .array(sheets)])
    }

    /// Whether these bytes open as a workbook at all — the cheap check before reading.
    static func looksLikeWorkbook(_ data: Data) -> Bool {
        ZipArchive.looksLikeArchive(data)
    }

    // MARK: - Relationships

    /// `Id → Target`, with targets resolved against the part's own directory.
    private static func relationships(in zip: ZipArchive, for part: String) -> [String: String] {
        guard let xml = zip.text(for: OOXMLPackage.relsPart(for: part)),
              let root = XMLElement.parse(xml) else { return [:] }
        let directory = part.contains("/") ? String(part[..<part.lastIndex(of: "/")!]) : ""
        var out: [String: String] = [:]
        for rel in root.descendants("Relationship") {
            guard let id = rel.attribute("Id"), let target = rel.attribute("Target") else { continue }
            out[id] = OOXMLPackage.resolve(target: target, from: directory)
        }
        return out
    }

    // MARK: - Styles

    private struct Styles {
        /// One entry per `cellXfs` index.
        var cells: [OOXMLValue?] = []
        /// One entry per `dxfs` index, for conditional formats.
        var differentials: [OOXMLValue?] = []
    }

    private static func readStyles(_ zip: ZipArchive) -> Styles {
        guard let xml = zip.text(for: XlsxMapping.stylesPart),
              let root = XMLElement.parse(xml) else { return Styles() }

        var formats = XlsxMapping.builtinFormats
        for format in root.descendants("numFmt") {
            guard let id = format.attribute("numFmtId").flatMap(Int.init),
                  let code = format.attribute("formatCode") else { continue }
            formats[id] = code
        }

        let fonts = (root.element("fonts")?.elements("font") ?? []).map(fontStyle)
        let fills = (root.element("fills")?.elements("fill") ?? []).map(fillColor)
        let borders = (root.element("borders")?.elements("border") ?? []).map(borderStyle)

        let cells = (root.element("cellXfs")?.elements("xf") ?? []).map { xf -> OOXMLValue? in
            var style: [String: OOXMLValue] = [:]
            if let font = fonts[safe: xf.attribute("fontId").flatMap(Int.init) ?? 0] {
                style.merge(font) { _, new in new }
            }
            if let border = borders[safe: xf.attribute("borderId").flatMap(Int.init) ?? 0] {
                style.merge(border) { _, new in new }
            }
            if let fill = fills[safe: xf.attribute("fillId").flatMap(Int.init) ?? 0] ?? nil {
                style["backgroundColor"] = .string(fill)
            }

            if let id = xf.attribute("numFmtId").flatMap(Int.init), let code = formats[id],
               code != "General" {
                if let structured = XlsxMapping.structuredFormat(code) {
                    style["numberFormat"] = .string(structured.kind)
                    if let decimals = structured.decimals {
                        style["decimalPlaces"] = .number(Double(decimals))
                    }
                } else {
                    style["customFormat"] = .string(code)
                }
            }

            if let alignment = xf.element("alignment") {
                if let h = alignment.attribute("horizontal"),
                   let mapped = XlsxMapping.horizontalAlignBack[h] {
                    style["textAlign"] = .string(mapped)
                }
                if let v = alignment.attribute("vertical"),
                   let mapped = XlsxMapping.verticalAlignBack[v] {
                    style["verticalAlign"] = .string(mapped)
                }
                if alignment.attribute("wrapText") == "1" { style["wrapMode"] = .string("wrap") }
            }
            return style.isEmpty ? nil : .object(style)
        }

        let differentials = (root.element("dxfs")?.elements("dxf") ?? []).map { dxf -> OOXMLValue? in
            var format: [String: OOXMLValue] = [:]
            if let font = dxf.element("font") {
                if font.element("b") != nil { format["fontWeight"] = .string("bold") }
                if font.element("i") != nil { format["fontStyle"] = .string("italic") }
                if font.element("u") != nil { format["textDecoration"] = .string("underline") }
                if let color = XlsxMapping.fromArgb(font.element("color")?.attribute("rgb")) {
                    format["color"] = .string(color)
                }
            }
            let pattern = dxf.element("fill")?.element("patternFill")
            let background = XlsxMapping.fromArgb(pattern?.element("bgColor")?.attribute("rgb"))
                ?? XlsxMapping.fromArgb(pattern?.element("fgColor")?.attribute("rgb"))
            if let background { format["backgroundColor"] = .string(background) }
            return format.isEmpty ? nil : .object(format)
        }

        return Styles(cells: cells, differentials: differentials)
    }

    private static func fontStyle(_ font: XMLElement) -> [String: OOXMLValue] {
        var style: [String: OOXMLValue] = [:]
        if font.element("b") != nil { style["fontWeight"] = .string("bold") }
        if font.element("i") != nil { style["fontStyle"] = .string("italic") }
        if font.element("strike") != nil { style["textDecoration"] = .string("line-through") }
        // 11pt is the default every workbook opens at, so recording it would put a font size on
        // every cell of a file that never set one.
        if let size = font.element("sz")?.attribute("val").flatMap(Double.init), size != 11 {
            style["fontSize"] = .string("\(XlsxMapping.number(size))pt")
        }
        if let color = XlsxMapping.fromArgb(font.element("color")?.attribute("rgb")) {
            style["color"] = .string(color)
        }
        if let name = font.element("name")?.attribute("val"), name != "Calibri" {
            style["fontFamily"] = .string(name)
        }
        return style
    }

    private static func fillColor(_ fill: XMLElement) -> String? {
        guard let pattern = fill.element("patternFill"),
              pattern.attribute("patternType") == "solid" else { return nil }
        return XlsxMapping.fromArgb(pattern.element("fgColor")?.attribute("rgb"))
    }

    private static func borderStyle(_ border: XMLElement) -> [String: OOXMLValue] {
        var style: [String: OOXMLValue] = [:]
        for side in XlsxMapping.borderSides {
            guard let weight = XlsxMapping.borderWeight(
                border.element(side.tag)?.attribute("style")) else { continue }
            style[side.key] = .string(weight)
        }
        return style
    }

    // MARK: - Shared strings

    private static func readSharedStrings(_ zip: ZipArchive) -> [String] {
        guard let xml = zip.text(for: XlsxMapping.sharedStringsPart),
              let root = XMLElement.parse(xml) else { return [] }
        // A rich-text string is a list of runs; their text concatenated is the string, and the run
        // formatting is not something a cell can hold here.
        return root.elements("si").map { si in
            si.descendants("t").map(\.textContent).joined()
        }
    }

    // MARK: - Cells

    private static func readCell(_ c: XMLElement, shared: [String],
                                 styles: Styles) -> (id: String, cell: [String: OOXMLValue])? {
        guard let id = c.attribute("r"), XlsxMapping.parseCellID(id) != nil else { return nil }
        let type = c.attribute("t") ?? "n"
        let styleIndex = c.attribute("s").flatMap(Int.init) ?? 0
        let cellStyle = styles.cells[safe: styleIndex] ?? nil

        let rawValue = c.element("v")?.textContent ?? ""
        let display: String
        switch type {
        case "inlineStr":
            display = (c.element("is") ?? c).descendants("t").map(\.textContent).joined()
        case "s":
            display = shared[safe: Int(rawValue) ?? -1] ?? ""
        case "b":
            display = rawValue == "1" ? "TRUE" : "FALSE"
        default:
            display = rawValue
        }

        let formula = c.element("f")?.textContent ?? ""
        let raw = formula.isEmpty ? display : "=\(formula)"
        if raw.isEmpty && display.isEmpty && cellStyle == nil { return nil }

        var cell: [String: OOXMLValue] = [
            "id": .string(id), "raw": .string(raw), "value": .string(display),
        ]
        if let cellStyle { cell["cellStyle"] = cellStyle }
        return (id, cell)
    }

    // MARK: - Worksheets

    private static func readSheet(_ root: XMLElement, path: String, name: String, index: Int,
                                  zip: ZipArchive, styles: Styles, shared: [String],
                                  extra: OOXMLValue?) -> OOXMLValue {
        var sheet: [String: OOXMLValue] = ["name": .string(name)]

        if let tabColor = XlsxMapping.fromArgb(
            root.element("sheetPr")?.element("tabColor")?.attribute("rgb")) {
            sheet["color"] = .string(tabColor)
        }

        // ── Cells.
        let clipped = Set((extra?["clipped"]?.arrayValue ?? []).compactMap(\.stringValue))
        var cells: [String: OOXMLValue] = [:]
        let sheetData = root.element("sheetData")
        for row in sheetData?.elements("row") ?? [] {
            for c in row.elements("c") {
                guard var entry = readCell(c, shared: shared, styles: styles) else { continue }
                // OOXML has `wrapText` and no third state, so `clip` comes back from the extras
                // entry; `overflow` is the absence of both.
                if clipped.contains(entry.id) {
                    var style = entry.cell["cellStyle"]?.objectValue ?? [:]
                    style["wrapMode"] = .string("clip")
                    entry.cell["cellStyle"] = .object(style)
                }
                cells[entry.id] = .object(entry.cell)
            }
        }

        // ── Column widths and row heights, both 0-based in the model.
        var colWidths: [String: OOXMLValue] = [:]
        for col in root.element("cols")?.elements("col") ?? [] {
            guard let width = col.attribute("width").flatMap(Double.init),
                  let min = col.attribute("min").flatMap(Int.init) else { continue }
            let max = col.attribute("max").flatMap(Int.init) ?? min
            guard min <= max else { continue }
            // One `<col>` can size a span of columns; the model is one entry each.
            for i in min...max {
                colWidths[String(i - 1)] = .number(XlsxMapping.charWidthToPx(width))
            }
        }
        if !colWidths.isEmpty { sheet["colWidths"] = .object(colWidths) }

        var rowHeights: [String: OOXMLValue] = [:]
        for row in sheetData?.elements("row") ?? [] {
            guard let r = row.attribute("r").flatMap(Int.init),
                  let ht = row.attribute("ht").flatMap(Double.init),
                  row.attribute("customHeight") == "1" else { continue }
            rowHeights[String(r - 1)] = .number(XlsxMapping.pointsToPx(ht))
        }
        if !rowHeights.isEmpty { sheet["rowHeights"] = .object(rowHeights) }

        // ── Merges, expanded back onto every covered cell.
        for merge in root.element("mergeCells")?.elements("mergeCell") ?? [] {
            guard let ref = merge.attribute("ref") else { continue }
            let bounds = ref.split(separator: ":").map(String.init)
            guard bounds.count == 2, let start = XlsxMapping.parseCellID(bounds[0]),
                  let end = XlsxMapping.parseCellID(bounds[1]),
                  start.column <= end.column, start.row <= end.row else { continue }
            let anchor = bounds[0]
            var anchorCell = cells[anchor]?.objectValue
                ?? ["id": .string(anchor), "raw": .string(""), "value": .string("")]
            anchorCell["colSpan"] = .number(Double(end.column - start.column + 1))
            anchorCell["rowSpan"] = .number(Double(end.row - start.row + 1))
            cells[anchor] = .object(anchorCell)
            for c in start.column...end.column {
                for r in start.row...end.row {
                    let id = "\(XlsxMapping.numberToColumn(c))\(r)"
                    if id == anchor { continue }
                    var covered = cells[id]?.objectValue
                        ?? ["id": .string(id), "raw": .string(""), "value": .string("")]
                    covered["mergeAnchor"] = .string(anchor)
                    cells[id] = .object(covered)
                }
            }
        }
        sheet["cells"] = .object(cells)

        // ── Conditional formats, then the extras overlay by rule index.
        var rules: [OOXMLValue] = []
        for block in root.elements("conditionalFormatting") {
            let range = block.attribute("sqref") ?? ""
            for rule in block.elements("cfRule") {
                guard let parsed = readCFRule(rule, range: range, index: rules.count,
                                              sheet: index, styles: styles) else { continue }
                rules.append(parsed)
            }
        }
        for (key, rule) in (extra?["conditionalFormats"]?.objectValue ?? [:]).sorted(by: {
            (Int($0.key) ?? 0) < (Int($1.key) ?? 0)
        }) {
            guard let at = Int(key), at >= 0 else { continue }
            if at < rules.count { rules[at] = rule } else if at == rules.count { rules.append(rule) }
        }
        if !rules.isEmpty { sheet["conditionalFormats"] = .array(rules) }
        if let variables = extra?["cfVariables"]?.arrayValue, !variables.isEmpty {
            sheet["cfVariables"] = .array(variables)
        }

        // ── Tables.
        let partIDs = (root.element("tableParts")?.elements("tablePart") ?? [])
            .compactMap { $0.attribute("id", uri: OOXMLNamespace.r) }
        if !partIDs.isEmpty {
            let sheetRels = relationships(in: zip, for: path)
            var regions: [OOXMLValue] = []
            for (position, id) in partIDs.enumerated() {
                guard let target = sheetRels[id], let xml = zip.text(for: target),
                      let table = XMLElement.parse(xml), let ref = table.attribute("ref"),
                      let region = tableRegion(ref, index: position, sheet: index,
                                               styleID: extra?["tableStyles"]?[String(position)]?
                                                   .stringValue) else { continue }
                regions.append(region)
            }
            if !regions.isEmpty { sheet["tables"] = .array(regions) }
        }

        if let charts = extra?["charts"]?.arrayValue, !charts.isEmpty {
            sheet["charts"] = .array(charts)
        }
        return .object(sheet)
    }

    // MARK: - Conditional formats

    private static func readCFRule(_ rule: XMLElement, range: String, index: Int, sheet: Int,
                                   styles: Styles) -> OOXMLValue? {
        let type = rule.attribute("type") ?? ""
        let format: OOXMLValue = rule.attribute("dxfId").flatMap(Int.init)
            .flatMap { styles.differentials[safe: $0] ?? nil } ?? .object([:])
        let formulas = rule.elements("formula").map(\.textContent)

        func wrap(_ spec: [String: OOXMLValue]) -> OOXMLValue {
            var base: [String: OOXMLValue] = [
                "id": .string("cf-\(sheet)-\(index)"), "range": .string(range),
                "rule": .object(spec),
            ]
            if rule.attribute("stopIfTrue") == "1" { base["stopIfTrue"] = .bool(true) }
            return .object(base)
        }
        func unquote(_ value: String) -> String {
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }

        switch type {
        case "cellIs":
            guard let condition = XlsxMapping.cfOperatorBack[rule.attribute("operator") ?? ""] else {
                return nil
            }
            var spec: [String: OOXMLValue] = [
                "kind": .string("singleColor"), "condition": .string(condition),
                "value": .string(unquote(formulas.first ?? "")), "format": format,
            ]
            if formulas.count > 1 { spec["value2"] = .string(unquote(formulas[1])) }
            return wrap(spec)

        case "containsText":
            return wrap(["kind": .string("singleColor"), "condition": .string("containsText"),
                         "value": .string(rule.attribute("text") ?? ""), "format": format])

        case "containsBlanks":
            return wrap(["kind": .string("singleColor"), "condition": .string("isEmpty"),
                         "format": format])

        case "notContainsBlanks":
            return wrap(["kind": .string("singleColor"), "condition": .string("isNotEmpty"),
                         "format": format])

        case "timePeriod":
            guard let condition = XlsxMapping.cfTimePeriodBack[
                rule.attribute("timePeriod") ?? ""] else { return nil }
            return wrap(["kind": .string("singleColor"), "condition": .string(condition),
                         "format": format])

        case "expression":
            return wrap(["kind": .string("formula"),
                         "formula": .string("=\(formulas.first ?? "")"), "format": format])

        case "duplicateValues":
            return wrap(["kind": .string("duplicates"), "format": format])

        case "uniqueValues":
            return wrap(["kind": .string("uniques"), "format": format])

        case "top10":
            return wrap([
                "kind": .string("topBottom"),
                "direction": .string(rule.attribute("bottom") == "1" ? "bottom" : "top"),
                "type": .string(rule.attribute("percent") == "1" ? "percent" : "n"),
                "value": .number(Double(rule.attribute("rank").flatMap(Int.init) ?? 10)),
                "format": format,
            ])

        case "aboveAverage":
            return wrap([
                "kind": .string("average"),
                "direction": .string(rule.attribute("aboveAverage") == "0" ? "below" : "above"),
                "format": format,
            ])

        case "colorScale":
            let colors = (rule.element("colorScale")?.elements("color") ?? [])
                .compactMap { XlsxMapping.fromArgb($0.attribute("rgb")) }
            guard colors.count >= 2 else { return nil }
            if colors.count >= 3 {
                return wrap(["kind": .string("colorScale"), "minColor": .string(colors[0]),
                             "midColor": .string(colors[1]), "maxColor": .string(colors[2])])
            }
            return wrap(["kind": .string("colorScale"), "minColor": .string(colors[0]),
                         "maxColor": .string(colors[1])])

        case "dataBar":
            let color = XlsxMapping.fromArgb(
                rule.element("dataBar")?.element("color")?.attribute("rgb"))
            return wrap(["kind": .string("dataBar"), "color": .string(color ?? "#638ec6"),
                         "gradient": .bool(true)])

        case "iconSet":
            let set = XlsxMapping.cfIconSetBack[
                rule.element("iconSet")?.attribute("iconSet") ?? ""] ?? "trafficLights"
            return wrap(["kind": .string("iconSet"), "iconSet": .string(set)])

        default:
            return nil
        }
    }

    // MARK: - Tables

    /// The style id a table region falls back to when the extras part does not name one.
    ///
    /// `blank` is the first entry of the editor's `TABLE_STYLES`, which is what the web reader uses
    /// for a table that came from another tool.
    private static let defaultTableStyle = "blank"

    private static func tableRegion(_ ref: String, index: Int, sheet: Int,
                                    styleID: String?) -> OOXMLValue? {
        let bounds = ref.split(separator: ":").map(String.init)
        guard let start = XlsxMapping.parseCellID(bounds.first ?? ""),
              let end = XlsxMapping.parseCellID(bounds.count > 1 ? bounds[1] : bounds[0])
        else { return nil }
        return .object([
            "id": .string("table-\(sheet)-\(index)"),
            "styleId": .string(styleID ?? defaultTableStyle),
            "minR": .number(Double(start.row)), "maxR": .number(Double(end.row)),
            "minC": .number(Double(start.column)), "maxC": .number(Double(end.column)),
        ])
    }

    // MARK: - The extras part

    private static func readExtras(_ zip: ZipArchive) -> OOXMLValue {
        guard let xml = zip.text(for: XlsxMapping.extrasPart),
              let root = XMLElement.parse(xml),
              let payload = root.descendants("payload").first?.textContent,
              !payload.isEmpty,
              let parsed = OOXMLValue.parse(payload), parsed.objectValue != nil else {
            return .object([:])
        }
        return parsed
    }
}

// MARK: - Bounds-safe indexing

private extension Array {
    /// The element at `index`, or nil when it is out of range.
    ///
    /// Every index into the style tables comes out of the file being read, so one naming an entry
    /// that is not there is a malformed workbook rather than a programming error — and it must cost
    /// the cell's shading, not the spreadsheet.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
