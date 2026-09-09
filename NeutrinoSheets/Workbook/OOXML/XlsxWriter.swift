import Foundation
import NeutrinoOOXML

// MARK: - XlsxWriter

/// The sheets editor's model → a real `.xlsx`.
///
/// Every construct the editor holds is written as the SpreadsheetML element that means it: values
/// and formulas as `<v>`/`<f>`, number formats as `numFmt`, fonts, fills and borders as entries in
/// `styles.xml` that cells point at, merges as `<mergeCells>`, column widths as `<cols>`, row
/// heights as the `ht` on `<row>`, a tab colour as `<tabColor>`, conditional formats as `<cfRule>`,
/// and a table region as a real `xl/tables/` part. Excel does not see a projection of the
/// spreadsheet; it sees the spreadsheet.
///
/// Read this together with ``XlsxReader``: they are two halves of one mapping and
/// `XlsxRoundTripTests` asserts they agree. A change here with no counterpart there loses data.
///
/// The Swift half of `web/apps/web/src/lib/ooxml/xlsx/write.ts`.
enum XlsxWriter {

    // MARK: - Entry point

    /// `file` — the stored `{"sheets":[…]}` envelope — as `.xlsx` bytes.
    ///
    /// - Parameter keep: an existing package to preserve the unrecognised parts of — charts, pivot
    ///   tables, images and anything else another tool put there. Without it the workbook is written
    ///   from the model alone, which is what a new spreadsheet wants.
    static func write(_ file: OOXMLValue, keep: Data? = nil) throws -> Data {
        // The editor treats a workbook with no tabs as empty and keeps its own default; one empty
        // tab is what "this file was empty" means everywhere else.
        var sheets = file["sheets"]?.arrayValue ?? []
        if sheets.isEmpty { sheets = [.object(["name": .string("Sheet 1")])] }

        let names = XlsxMapping.tabNames(sheets.map { $0["name"]?.stringValue })
        let styles = StyleTable()

        var extras: [String: OOXMLValue] = [:]
        var written: [WrittenSheet] = []
        var tableID = 1
        for (index, sheet) in sheets.enumerated() {
            let out = writeSheet(sheet, styles: styles, tableIDBase: tableID)
            tableID += out.tables.count
            if !out.extra.isEmpty { extras[String(index)] = .object(out.extra) }
            written.append(out)
        }
        let hasExtras = !extras.isEmpty

        var zip = ZipArchive()

        for (index, sheet) in written.enumerated() {
            zip.set(XlsxMapping.worksheetPart(index + 1), text: sheet.xml)
            for table in sheet.tables { zip.set(table.path, text: table.xml) }
            if !sheet.tables.isEmpty {
                let rels = sheet.tables.enumerated().map { position, table in
                    "<Relationship Id=\"rId\(position + 1)\" Type=\"\(XlsxMapping.nsRel)/table\""
                        + " Target=\"../\(table.path.replacingOccurrences(of: "xl/", with: ""))\"/>"
                }.joined()
                zip.set(XlsxMapping.worksheetRelsPart(index + 1), text: relationships(rels))
            }
        }

        zip.set(XlsxMapping.stylesPart, text: styles.toXML())

        let sheetEntries = names.enumerated().map { index, name in
            "<sheet name=\"\(XlsxMapping.escape(name))\" sheetId=\"\(index + 1)\""
                + " r:id=\"rId\(index + 1)\"/>"
        }.joined()
        zip.set(XlsxMapping.workbookPart, text:
            "\(XlsxMapping.xmlDeclaration)<workbook xmlns=\"\(XlsxMapping.nsMain)\""
            + " xmlns:r=\"\(XlsxMapping.nsRel)\"><sheets>\(sheetEntries)</sheets></workbook>")

        let stylesRelID = names.count + 1
        let extrasRelID = names.count + 2
        var workbookRels = names.enumerated().map { index, _ in
            "<Relationship Id=\"rId\(index + 1)\" Type=\"\(XlsxMapping.nsRel)/worksheet\""
                + " Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }.joined()
        workbookRels += "<Relationship Id=\"rId\(stylesRelID)\" Type=\"\(XlsxMapping.nsRel)/styles\""
            + " Target=\"styles.xml\"/>"
        if hasExtras {
            workbookRels += "<Relationship Id=\"rId\(extrasRelID)\""
                + " Type=\"\(XlsxMapping.nsRel)/customXml\" Target=\"../\(XlsxMapping.extrasPart)\"/>"
        }
        zip.set(XlsxMapping.workbookRelsPart, text: relationships(workbookRels))

        zip.set(XlsxMapping.rootRelsPart, text: relationships(
            "<Relationship Id=\"rId1\" Type=\"\(XlsxMapping.nsRel)/officeDocument\""
            + " Target=\"xl/workbook.xml\"/>"))

        if hasExtras {
            zip.set(XlsxMapping.extrasPart, text: extrasXML(.object(["sheets": .object(extras)])))
            zip.set(XlsxMapping.extrasPropsPart, text:
                "\(XlsxMapping.xmlDeclaration)<ds:datastoreItem"
                + " xmlns:ds=\"\(OOXMLNamespace.customXml)\""
                + " ds:itemID=\"{4E9C2B71-9F3C-4E77-9E3E-1C2D3A4B5C6D}\">"
                + "<ds:schemaRefs><ds:schemaRef ds:uri=\"\(XlsxMapping.extrasNamespace)\"/>"
                + "</ds:schemaRefs></ds:datastoreItem>")
            zip.set("customXml/_rels/item1.xml.rels", text: relationships(
                "<Relationship Id=\"rId1\" Type=\"\(XlsxMapping.nsRel)/customXmlProps\""
                + " Target=\"itemProps1.xml\"/>"))
        }

        // Parts from a package this is replacing that nothing here understands.
        let carried = keep.map { carryForeignParts(into: &zip, from: $0) } ?? []

        var overrides = "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd"
            + ".openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        overrides += names.enumerated().map { index, _ in
            "<Override PartName=\"/\(XlsxMapping.worksheetPart(index + 1))\" ContentType=\"application"
                + "/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        overrides += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd"
            + ".openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        overrides += written.flatMap(\.tables).map { table in
            "<Override PartName=\"/\(table.path)\" ContentType=\"application/vnd.openxmlformats"
                + "-officedocument.spreadsheetml.table+xml\"/>"
        }.joined()
        if hasExtras {
            overrides += "<Override PartName=\"/\(XlsxMapping.extrasPropsPart)\""
                + " ContentType=\"application/vnd.openxmlformats-officedocument"
                + ".customXmlProperties+xml\"/>"
        }
        overrides += carried.joined()

        zip.set(OOXMLPackage.contentTypesPart, text:
            "\(XlsxMapping.xmlDeclaration)<Types xmlns=\"\(XlsxMapping.nsContentTypes)\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package"
            + ".relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Default Extension=\"png\" ContentType=\"image/png\"/>"
            + "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>"
            + "\(overrides)</Types>")

        return try zip.serialized()
    }

    private static func relationships(_ body: String) -> String {
        "\(XlsxMapping.xmlDeclaration)<Relationships xmlns=\"\(XlsxMapping.nsPackageRels)\">"
            + "\(body)</Relationships>"
    }

    // MARK: - Worksheets

    private struct TablePart {
        let path: String
        let xml: String
    }

    private struct WrittenSheet {
        let xml: String
        let tables: [TablePart]
        let extra: [String: OOXMLValue]
    }

    private static func writeSheet(_ sheet: OOXMLValue, styles: StyleTable,
                                   tableIDBase: Int) -> WrittenSheet {
        var extra: [String: OOXMLValue] = [:]
        let cells = sheet["cells"]?.objectValue ?? [:]

        // ── Cells, grouped into rows in ascending order, as OOXML requires.
        var rows: [Int: [(id: String, cell: OOXMLValue, column: Int)]] = [:]
        var maxColumn = 0
        var maxRow = 0
        var clipped: [String] = []
        for (id, cell) in cells {
            guard let at = XlsxMapping.parseCellID(id) else { continue }
            if cell["cellStyle"]?["wrapMode"]?.stringValue == "clip" { clipped.append(id) }
            rows[at.row, default: []].append((id, cell, at.column))
            maxColumn = max(maxColumn, at.column)
            maxRow = max(maxRow, at.row)
        }
        if !clipped.isEmpty {
            extra["clipped"] = .array(clipped.sorted().map { .string($0) })
        }

        let heights = sheet["rowHeights"]?.objectValue ?? [:]
        let rowXML = rows.keys.sorted().map { r -> String in
            let body = rows[r]!.sorted { $0.column < $1.column }
                .map { cellXML($0.id, $0.cell, styleIndex: styles.cellStyle($0.cell["cellStyle"])) }
                .joined()
            // Heights are keyed 0-based in the model and rows are 1-based here.
            let height = heights[String(r - 1)]?.doubleValue
            let ht = height.map {
                " ht=\"\(XlsxMapping.number(XlsxMapping.pxToPoints($0)))\" customHeight=\"1\""
            } ?? ""
            return "<row r=\"\(r)\"\(ht)>\(body)</row>"
        }.joined()

        // ── Column widths, one `<col>` per sized column.
        let widths = sheet["colWidths"]?.objectValue ?? [:]
        let colXML = widths.compactMap { key, value -> (index: Int, px: Double)? in
            guard let index = Int(key), let px = value.doubleValue else { return nil }
            return (index + 1, px)
        }
        .filter { $0.index > 0 }
        .sorted { $0.index < $1.index }
        .map { entry in
            "<col min=\"\(entry.index)\" max=\"\(entry.index)\""
                + " width=\"\(XlsxMapping.width(XlsxMapping.pxToCharWidth(entry.px)))\""
                + " customWidth=\"1\"/>"
        }.joined()

        // ── Merges, from the anchors; the covered cells are re-derived on read.
        var merges: [String] = []
        for (id, cell) in cells {
            let columns = cell["colSpan"]?.intValue ?? 1
            let spanRows = cell["rowSpan"]?.intValue ?? 1
            guard columns > 1 || spanRows > 1, let at = XlsxMapping.parseCellID(id) else { continue }
            let end = "\(XlsxMapping.numberToColumn(at.column + columns - 1))\(at.row + spanRows - 1)"
            merges.append("<mergeCell ref=\"\(id):\(end)\"/>")
        }
        merges.sort()
        let mergeXML = merges.isEmpty
            ? ""
            : "<mergeCells count=\"\(merges.count)\">\(merges.joined())</mergeCells>"

        // ── Conditional formats. One `<conditionalFormatting>` per rule keeps the model's order,
        // which is what the extras entries are indexed by.
        let context = CFContext(styles: styles)
        var cfExtras: [String: OOXMLValue] = [:]
        let cfXML = (sheet["conditionalFormats"]?.arrayValue ?? []).enumerated()
            .map { index, rule -> String in
                let spec = rule["rule"]
                let kind = spec?["kind"]?.stringValue ?? ""
                if XlsxMapping.needsCFExtra(kind: kind, condition: spec?["condition"]?.stringValue) {
                    cfExtras[String(index)] = rule
                }
                let body = cfRuleXML(rule, context: context)
                guard !body.isEmpty else { return "" }
                let range = rule["range"]?.stringValue ?? ""
                return "<conditionalFormatting sqref=\"\(XlsxMapping.escape(range))\">"
                    + "\(body)</conditionalFormatting>"
            }.joined()
        if !cfExtras.isEmpty { extra["conditionalFormats"] = .object(cfExtras) }
        if let variables = sheet["cfVariables"]?.arrayValue, !variables.isEmpty {
            extra["cfVariables"] = .array(variables)
        }

        // ── Tables. The region is a real table part; its Neutrino style id is not.
        var tables: [TablePart] = []
        var tableStyles: [String: OOXMLValue] = [:]
        var tableRels: [String] = []
        for (index, region) in (sheet["tables"]?.arrayValue ?? []).enumerated() {
            guard let minC = region["minC"]?.intValue, let maxC = region["maxC"]?.intValue,
                  let minR = region["minR"]?.intValue, let maxR = region["maxR"]?.intValue
            else { continue }
            let id = tableIDBase + tables.count
            let ref = "\(XlsxMapping.numberToColumn(minC))\(minR)"
                + ":\(XlsxMapping.numberToColumn(maxC))\(maxR)"
            var columns: [String] = []
            for c in minC...max(minC, maxC) {
                let header = cells["\(XlsxMapping.numberToColumn(c))\(minR)"]?["raw"]?
                    .stringValue?.trimmingCharacters(in: .whitespaces)
                let name = (header?.isEmpty == false) ? header! : "Column\(c - minC + 1)"
                columns.append("<tableColumn id=\"\(c - minC + 1)\""
                    + " name=\"\(XlsxMapping.escape(name))\"/>")
            }
            tables.append(TablePart(path: XlsxMapping.tablePart(id), xml:
                "\(XlsxMapping.xmlDeclaration)<table xmlns=\"\(XlsxMapping.nsMain)\" id=\"\(id)\""
                + " name=\"Table\(id)\" displayName=\"Table\(id)\" ref=\"\(ref)\" totalsRowShown=\"0\">"
                + "<autoFilter ref=\"\(ref)\"/>"
                + "<tableColumns count=\"\(columns.count)\">\(columns.joined())</tableColumns>"
                + "<tableStyleInfo name=\"TableStyleMedium2\" showFirstColumn=\"0\""
                + " showLastColumn=\"0\" showRowStripes=\"1\" showColumnStripes=\"0\"/></table>"))
            tableRels.append("<tablePart r:id=\"rId\(tables.count)\"/>")
            if let styleID = region["styleId"]?.stringValue {
                tableStyles[String(index)] = .string(styleID)
            }
        }
        if !tableStyles.isEmpty { extra["tableStyles"] = .object(tableStyles) }
        if let charts = sheet["charts"]?.arrayValue, !charts.isEmpty {
            extra["charts"] = .array(charts)
        }

        let tabColor = XlsxMapping.toArgb(sheet["color"]?.stringValue)
        let dimension = maxRow > 0
            ? "<dimension ref=\"A1:\(XlsxMapping.numberToColumn(maxColumn))\(maxRow)\"/>"
            : ""
        // The element order below is the schema's, and Excel enforces it.
        var xml = "\(XlsxMapping.xmlDeclaration)<worksheet xmlns=\"\(XlsxMapping.nsMain)\""
            + " xmlns:r=\"\(XlsxMapping.nsRel)\">"
        if let tabColor { xml += "<sheetPr><tabColor rgb=\"\(tabColor)\"/></sheetPr>" }
        xml += dimension
        xml += "<sheetFormatPr defaultRowHeight=\"15\"/>"
        if !colXML.isEmpty { xml += "<cols>\(colXML)</cols>" }
        xml += "<sheetData>\(rowXML)</sheetData>"
        xml += mergeXML
        xml += cfXML
        if !tableRels.isEmpty {
            xml += "<tableParts count=\"\(tableRels.count)\">\(tableRels.joined())</tableParts>"
        }
        xml += "</worksheet>"

        return WrittenSheet(xml: xml, tables: tables, extra: extra)
    }

    // MARK: - Cells

    /// Whether text is a number OOXML can store as one, matched narrowly.
    ///
    /// Narrowly because a permissive parse accepts a great deal that must *not* become a number in a
    /// spreadsheet: `0015` is a product code, `1e5` and `0x1f` are text someone typed, and storing
    /// any of them as their numeric value loses the cell the user entered. Leading zeros are the
    /// case that actually bites — a column of zip codes silently loses its first digit.
    static func numericValue(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        var body = Substring(text)
        if body.hasPrefix("-") { body = body.dropFirst() }
        guard !body.isEmpty else { return nil }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = parts[0]
        let fraction = parts.count == 2 ? parts[1] : nil

        // `.5` is a number; `5.` is not, and neither is `007`.
        if whole.isEmpty {
            guard let fraction, !fraction.isEmpty else { return nil }
        } else {
            guard whole.allSatisfy(\.isNumber) else { return nil }
            if whole.count > 1 && whole.hasPrefix("0") { return nil }
        }
        if let fraction {
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func cellXML(_ id: String, _ cell: OOXMLValue, styleIndex: Int) -> String {
        let s = styleIndex != 0 ? " s=\"\(styleIndex)\"" : ""
        // `raw` is what the user typed and is what a cell is written from. Falling back to the
        // cached `value` matters for a cell that has one and no `raw`: the reader always produces
        // both, but a caller building a workbook in code need not, and writing nothing at all would
        // drop the cell silently.
        let raw = cell["raw"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? cell["value"]?.stringValue ?? ""
        if raw.hasPrefix("=") {
            // The cached value goes in beside the formula, so a reader that does not evaluate —
            // Excel before a recalculation, and `XlsxReader` — still has it.
            let formula = XlsxMapping.escape(String(raw.dropFirst()))
            let cached = cell["value"]?.stringValue ?? ""
            if let numeric = numericValue(cached) {
                return "<c r=\"\(id)\"\(s)><f>\(formula)</f>"
                    + "<v>\(XlsxMapping.number(numeric))</v></c>"
            }
            if cached.isEmpty { return "<c r=\"\(id)\"\(s)><f>\(formula)</f></c>" }
            return "<c r=\"\(id)\"\(s) t=\"str\"><f>\(formula)</f>"
                + "<v>\(XlsxMapping.escape(cached))</v></c>"
        }
        if let numeric = numericValue(raw) {
            return "<c r=\"\(id)\"\(s)><v>\(XlsxMapping.number(numeric))</v></c>"
        }
        if raw.isEmpty { return s.isEmpty ? "" : "<c r=\"\(id)\"\(s)/>" }
        // Inline rather than shared strings: one fewer part, one fewer table to keep consistent, and
        // no measurable size difference at spreadsheet scale.
        return "<c r=\"\(id)\"\(s) t=\"inlineStr\"><is>"
            + "<t xml:space=\"preserve\">\(XlsxMapping.escape(raw))</t></is></c>"
    }

    // MARK: - Conditional formats

    private final class CFContext {
        let styles: StyleTable
        private var next = 1

        init(styles: StyleTable) { self.styles = styles }

        func priority() -> String {
            defer { next += 1 }
            return " priority=\"\(next)\""
        }
    }

    /// The top-left cell of a range, which relative CF formulas are written against.
    private static func firstCell(of range: String) -> String {
        let first = (range.split(separator: ":").first.map(String.init) ?? "")
            .replacingOccurrences(of: "$", with: "")
        return XlsxMapping.parseCellID(first) != nil ? first : "A1"
    }

    /// One rule as a `<cfRule>` element.
    ///
    /// A rule OOXML has an operator for is written as itself. One it does not — a progress bar, a
    /// status indicator, a heat map, a theme token, a reference to a named variable — is written as
    /// the nearest thing OOXML *does* have, so a workbook opened in Excel shows the cell as flagged
    /// rather than as plain, and the caller records the exact rule in the extras part.
    private static func cfRuleXML(_ rule: OOXMLValue, context: CFContext) -> String {
        guard let spec = rule["rule"], let kind = spec["kind"]?.stringValue else { return "" }
        let stop = rule["stopIfTrue"]?.boolValue == true ? " stopIfTrue=\"1\"" : ""
        let anchor = firstCell(of: rule["range"]?.stringValue ?? "")
        func dxf(_ format: OOXMLValue?) -> String {
            guard let id = context.styles.differential(format) else { return "" }
            return " dxfId=\"\(id)\""
        }

        switch kind {
        case "singleColor":
            return singleColorXML(spec, format: spec["format"], stop: stop, anchor: anchor,
                                  context: context)

        case "formula":
            let formula = spec["formula"]?.stringValue ?? ""
            let body = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
            return "<cfRule type=\"expression\"\(dxf(spec["format"]))\(context.priority())\(stop)>"
                + "<formula>\(XlsxMapping.escape(body))</formula></cfRule>"

        case "duplicates", "uniques":
            let type = kind == "duplicates" ? "duplicateValues" : "uniqueValues"
            return "<cfRule type=\"\(type)\"\(dxf(spec["format"]))\(context.priority())\(stop)/>"

        case "topBottom":
            let rank = spec["value"]?.intValue ?? 10
            let bottom = spec["direction"]?.stringValue == "bottom" ? " bottom=\"1\"" : ""
            let percent = spec["type"]?.stringValue == "percent" ? " percent=\"1\"" : ""
            return "<cfRule type=\"top10\"\(dxf(spec["format"]))\(context.priority())\(stop)"
                + " rank=\"\(rank)\"\(bottom)\(percent)/>"

        case "average":
            let below = spec["direction"]?.stringValue == "below" ? " aboveAverage=\"0\"" : ""
            return "<cfRule type=\"aboveAverage\"\(dxf(spec["format"]))"
                + "\(context.priority())\(stop)\(below)/>"

        case "colorScale":
            var colors = [spec["minColor"]?.stringValue ?? ""]
            if let mid = spec["midColor"]?.stringValue { colors.append(mid) }
            colors.append(spec["maxColor"]?.stringValue ?? "")
            return colorScaleXML(colors, priority: context.priority(), stop: stop)

        case "heatMap":
            let preset = XlsxMapping.cfHeatMapPresets[spec["preset"]?.stringValue ?? ""]
                ?? XlsxMapping.cfHeatMapPresets["financial"]!
            let low = spec["lowColor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? preset[0]
            let mid = spec["midColor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? preset[1]
            let high = spec["highColor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? preset[2]
            return colorScaleXML([low, mid, high], priority: context.priority(), stop: stop)

        case "dataBar":
            return dataBarXML(spec["color"]?.stringValue, priority: context.priority(), stop: stop)

        case "progressBar":
            // A data bar is what a progress bar is, minus the explicit range and the label; both
            // come back from the extras entry.
            return dataBarXML(spec["color"]?.stringValue, priority: context.priority(), stop: stop,
                              min: spec["minValue"]?.doubleValue, max: spec["maxValue"]?.doubleValue)

        case "iconSet":
            let set = XlsxMapping.cfIconSet[spec["iconSet"]?.stringValue ?? ""] ?? "3TrafficLights1"
            return iconSetXML(set, priority: context.priority(), stop: stop)

        case "statusIndicator":
            // Three states, however the template names them.
            return iconSetXML("3TrafficLights1", priority: context.priority(), stop: stop)

        case "themeColor":
            let token = spec["token"]?.stringValue ?? ""
            let colors = XlsxMapping.cfThemeColors[token]
            let format: OOXMLValue = colors.map {
                .object(["backgroundColor": .string($0.background), "color": .string($0.color)])
            } ?? .object([:])
            var recast: [String: OOXMLValue] = ["kind": .string("singleColor"), "format": format]
            for key in ["condition", "value", "value2"] {
                if let value = spec[key] { recast[key] = value }
            }
            return singleColorXML(.object(recast), format: format, stop: stop, anchor: anchor,
                                  context: context)

        case "variable":
            // The definition lives in `cfVariables`, which is itself an extras entry, and resolving
            // it belongs to the editor. A rule that never fires is written so the position is still
            // occupied: the extras entries are indexed by rule order, and a gap here would shift
            // every one after it.
            return "<cfRule type=\"expression\"\(context.priority())\(stop)>"
                + "<formula>FALSE()</formula></cfRule>"

        default:
            return ""
        }
    }

    private static func singleColorXML(_ spec: OOXMLValue, format: OOXMLValue?, stop: String,
                                       anchor: String, context: CFContext) -> String {
        let dxfAttribute = context.styles.differential(format).map { " dxfId=\"\($0)\"" } ?? ""
        let condition = spec["condition"]?.stringValue ?? ""
        let text = spec["value"]?.stringValue ?? ""

        if condition == "isEmpty" || condition == "isNotEmpty" {
            let type = condition == "isEmpty" ? "containsBlanks" : "notContainsBlanks"
            let formula = condition == "isEmpty"
                ? "LEN(TRIM(\(anchor)))=0"
                : "LEN(TRIM(\(anchor)))&gt;0"
            return "<cfRule type=\"\(type)\"\(dxfAttribute)\(context.priority())\(stop)>"
                + "<formula>\(formula)</formula></cfRule>"
        }
        if condition == "containsText" {
            let quoted = "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
            return "<cfRule type=\"containsText\"\(dxfAttribute)\(context.priority())\(stop)"
                + " operator=\"containsText\" text=\"\(XlsxMapping.escape(text))\">"
                + "<formula>NOT(ISERROR(SEARCH(\(XlsxMapping.escape(quoted)),\(anchor))))</formula>"
                + "</cfRule>"
        }
        if let period = XlsxMapping.cfTimePeriod[condition] {
            return "<cfRule type=\"timePeriod\"\(dxfAttribute)\(context.priority())\(stop)"
                + " timePeriod=\"\(period)\"><formula>FLOOR(\(anchor),1)=TODAY()</formula></cfRule>"
        }
        if condition == "dateIsPastDue" {
            // No `timePeriod` means "before today", so it is written as the comparison it is; the
            // extras entry is what restores the date framing.
            return "<cfRule type=\"cellIs\"\(dxfAttribute)\(context.priority())\(stop)"
                + " operator=\"lessThan\"><formula>TODAY()</formula></cfRule>"
        }
        guard let op = XlsxMapping.cfOperator[condition] else { return "" }
        let formulas = op == "between"
            ? "<formula>\(cfValue(spec["value"]?.stringValue))</formula>"
                + "<formula>\(cfValue(spec["value2"]?.stringValue))</formula>"
            : "<formula>\(cfValue(spec["value"]?.stringValue))</formula>"
        return "<cfRule type=\"cellIs\"\(dxfAttribute)\(context.priority())\(stop)"
            + " operator=\"\(op)\">\(formulas)</cfRule>"
    }

    /// A CF comparison value: a number as itself, anything else quoted.
    private static func cfValue(_ value: String?) -> String {
        let text = value ?? ""
        if !text.trimmingCharacters(in: .whitespaces).isEmpty, let number = Double(text),
           number.isFinite {
            return text
        }
        return XlsxMapping.escape("\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"")
    }

    private static func colorScaleXML(_ colors: [String], priority: String, stop: String) -> String {
        let points = colors.count == 3
            ? "<cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/>"
            : "<cfvo type=\"min\"/><cfvo type=\"max\"/>"
        let rgb = colors.map { "<color rgb=\"\(XlsxMapping.toArgb($0) ?? "FFFFFFFF")\"/>" }.joined()
        return "<cfRule type=\"colorScale\"\(priority)\(stop)><colorScale>\(points)\(rgb)"
            + "</colorScale></cfRule>"
    }

    private static func dataBarXML(_ color: String?, priority: String, stop: String,
                                   min: Double? = nil, max: Double? = nil) -> String {
        let low = min.map { "<cfvo type=\"num\" val=\"\(XlsxMapping.number($0))\"/>" }
            ?? "<cfvo type=\"min\"/>"
        let high = max.map { "<cfvo type=\"num\" val=\"\(XlsxMapping.number($0))\"/>" }
            ?? "<cfvo type=\"max\"/>"
        return "<cfRule type=\"dataBar\"\(priority)\(stop)><dataBar>\(low)\(high)"
            + "<color rgb=\"\(XlsxMapping.toArgb(color) ?? "FF638EC6")\"/></dataBar></cfRule>"
    }

    private static func iconSetXML(_ set: String, priority: String, stop: String) -> String {
        "<cfRule type=\"iconSet\"\(priority)\(stop)><iconSet iconSet=\"\(set)\">"
            + "<cfvo type=\"percent\" val=\"0\"/><cfvo type=\"percent\" val=\"33\"/>"
            + "<cfvo type=\"percent\" val=\"67\"/></iconSet></cfRule>"
    }

    // MARK: - The extras part

    private static func extrasXML(_ extras: OOXMLValue) -> String {
        "\(XlsxMapping.xmlDeclaration)<sheetExtras xmlns=\"\(XlsxMapping.extrasNamespace)\""
            + " version=\"1\"><payload>\(XlsxMapping.escape(extras.serializedString()))</payload>"
            + "</sheetExtras>"
    }

    // MARK: - Foreign parts

    /// Copy the parts of `previous` this writer has no notion of into `zip`, and return the
    /// content-type overrides they need.
    ///
    /// A workbook that has been through Excel can carry pivot tables, images, VML and charts. None
    /// of them are written here, and dropping them on every save would make Neutrino the tool that
    /// quietly deletes your pivot table. They are carried instead — inert, but still in the file when
    /// it goes back to Excel.
    ///
    /// Only parts under `xl/` that this writer does not itself produce are taken, and never the
    /// relationship files, which name parts by ids this rewrites.
    private static func carryForeignParts(into zip: inout ZipArchive, from previous: Data) -> [String] {
        guard let old = try? ZipArchive(data: previous) else { return [] }
        let types = contentTypes(of: old)
        var overrides: [String] = []
        for path in old.names {
            guard path.hasPrefix("xl/"), !isOurs(path), !path.contains("/_rels/"),
                  !zip.contains(path), let data = old.data(for: path) else { continue }
            zip.set(path, data: data)
            if let type = types["/\(path)"] {
                overrides.append("<Override PartName=\"/\(path)\" ContentType=\"\(type)\"/>")
            }
        }
        return overrides
    }

    private static func isOurs(_ path: String) -> Bool {
        path == XlsxMapping.workbookPart || path == XlsxMapping.stylesPart
            || path == XlsxMapping.sharedStringsPart
            || path.hasPrefix("xl/worksheets/") || path.hasPrefix("xl/tables/")
    }

    /// The `[Content_Types].xml` overrides of a package, by part name.
    private static func contentTypes(of zip: ZipArchive) -> [String: String] {
        guard let xml = zip.text(for: OOXMLPackage.contentTypesPart),
              let root = XMLElement.parse(xml) else { return [:] }
        var out: [String: String] = [:]
        for override in root.descendants("Override") {
            guard let name = override.attribute("PartName"),
                  let type = override.attribute("ContentType") else { continue }
            out[name] = type
        }
        return out
    }
}

// MARK: - StyleTable

/// `styles.xml` is a set of tables that cells index into, so every distinct font, fill, border and
/// format is written once however many cells wear it. This accumulates them and hands back the index
/// to put on the cell.
private final class StyleTable {

    private var numberFormats: [String: Int] = [:]
    private var fonts: [String: Int] = [:]
    private var fills: [String: Int] = [:]
    private var borders: [String: Int] = [:]
    private var xfs: [String: Int] = ["0|0|0|0|": 0]

    private var fontXML = ["<font><sz val=\"11\"/><name val=\"Calibri\"/></font>"]
    private var fillXML = [
        "<fill><patternFill patternType=\"none\"/></fill>",
        "<fill><patternFill patternType=\"gray125\"/></fill>",
    ]
    private var borderXML = ["<border><left/><right/><top/><bottom/><diagonal/></border>"]
    private var xfXML = ["<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"]
    private var numberFormatXML: [String] = []
    /// Differential formats, which conditional-format rules point at.
    private var dxfXML: [String] = []

    /// The `cellXfs` index for a cell style; 0 for a cell with none.
    func cellStyle(_ style: OOXMLValue?) -> Int {
        guard let style, let members = style.objectValue, !members.isEmpty else { return 0 }
        let numFmtID = numberFormat(style)
        let fontID = font(style)
        let fillID = fill(style)
        let borderID = border(style)
        let alignment = alignmentXML(style)
        let key = "\(numFmtID)|\(fontID)|\(fillID)|\(borderID)|\(alignment)"
        if let existing = xfs[key] { return existing }

        let index = xfXML.count
        var applies = ""
        if numFmtID != 0 { applies += " applyNumberFormat=\"1\"" }
        if fontID != 0 { applies += " applyFont=\"1\"" }
        if fillID != 0 { applies += " applyFill=\"1\"" }
        if borderID != 0 { applies += " applyBorder=\"1\"" }
        if !alignment.isEmpty { applies += " applyAlignment=\"1\"" }
        xfXML.append("<xf numFmtId=\"\(numFmtID)\" fontId=\"\(fontID)\" fillId=\"\(fillID)\""
            + " borderId=\"\(borderID)\" xfId=\"0\"\(applies)>\(alignment)</xf>")
        xfs[key] = index
        return index
    }

    /// The `dxfs` index for a conditional format's styling.
    func differential(_ format: OOXMLValue?) -> Int? {
        guard let format, let members = format.objectValue, !members.isEmpty else { return nil }
        var font = ""
        if format["fontWeight"]?.stringValue == "bold" { font += "<b/>" }
        if format["fontStyle"]?.stringValue == "italic" { font += "<i/>" }
        if format["textDecoration"]?.stringValue == "underline" { font += "<u/>" }
        if let color = XlsxMapping.toArgb(format["color"]?.stringValue) {
            font += "<color rgb=\"\(color)\"/>"
        }
        var parts = font.isEmpty ? "" : "<font>\(font)</font>"
        if let background = XlsxMapping.toArgb(format["backgroundColor"]?.stringValue) {
            parts += "<fill><patternFill><bgColor rgb=\"\(background)\"/></patternFill></fill>"
        }
        guard !parts.isEmpty else { return nil }
        let index = dxfXML.count
        dxfXML.append("<dxf>\(parts)</dxf>")
        return index
    }

    private func numberFormat(_ style: OOXMLValue) -> Int {
        let code = XlsxMapping.formatCode(numberFormat: style["numberFormat"]?.stringValue,
                                          decimalPlaces: style["decimalPlaces"]?.intValue,
                                          customFormat: style["customFormat"]?.stringValue)
        guard let code, code != "General" else { return 0 }
        for (id, builtin) in XlsxMapping.builtinFormats where builtin == code { return id }
        if let existing = numberFormats[code] { return existing }
        let id = XlsxMapping.firstCustomFormatID + numberFormats.count
        numberFormats[code] = id
        numberFormatXML.append("<numFmt numFmtId=\"\(id)\""
            + " formatCode=\"\(XlsxMapping.escape(code))\"/>")
        return id
    }

    private func font(_ style: OOXMLValue) -> Int {
        var parts = ""
        if style["fontWeight"]?.stringValue == "bold" { parts += "<b/>" }
        if style["fontStyle"]?.stringValue == "italic" { parts += "<i/>" }
        if style["textDecoration"]?.stringValue == "line-through" { parts += "<strike/>" }
        let size = style["fontSize"]?.stringValue.flatMap(Self.leadingNumber)
        parts += "<sz val=\"\(XlsxMapping.number(size ?? 11))\"/>"
        if let color = XlsxMapping.toArgb(style["color"]?.stringValue) {
            parts += "<color rgb=\"\(color)\"/>"
        }
        let family = style["fontFamily"]?.stringValue
        let name = (family?.isEmpty == false) ? family! : "Calibri"
        parts += "<name val=\"\(XlsxMapping.escape(name))\"/>"
        return intern("<font>\(parts)</font>", into: &fontXML, seen: &fonts, empty: 0)
    }

    private func fill(_ style: OOXMLValue) -> Int {
        guard let color = XlsxMapping.toArgb(style["backgroundColor"]?.stringValue) else { return 0 }
        // `fgColor` is the one that paints for a solid pattern; `bgColor` is behind it and shows
        // through only for the hatched patterns.
        let xml = "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(color)\"/>"
            + "<bgColor indexed=\"64\"/></patternFill></fill>"
        return intern(xml, into: &fillXML, seen: &fills, empty: 0)
    }

    private func border(_ style: OOXMLValue) -> Int {
        // A per-side value overrides the all-sides one, the way the editor's CSS does.
        let all = style["borderStyle"]?.stringValue
        let parts = XlsxMapping.borderSides.map { side -> String in
            let weight = XlsxMapping.borderStyleName(style[side.key]?.stringValue ?? all)
            guard let weight else { return "<\(side.tag)/>" }
            return "<\(side.tag) style=\"\(weight)\"><color rgb=\"FF000000\"/></\(side.tag)>"
        }.joined()
        // OOXML wants the sides in this order and a diagonal after them.
        return intern("<border>\(parts)<diagonal/></border>", into: &borderXML, seen: &borders,
                      empty: 0)
    }

    private func intern(_ value: String, into xml: inout [String], seen: inout [String: Int],
                        empty: Int) -> Int {
        if let existing = seen[value] { return existing }
        if value == xml[empty] { return empty }
        let index = xml.count
        xml.append(value)
        seen[value] = index
        return index
    }

    private func alignmentXML(_ style: OOXMLValue) -> String {
        let horizontal = style["textAlign"]?.stringValue.flatMap { XlsxMapping.horizontalAlign[$0] }
        let vertical = style["verticalAlign"]?.stringValue.flatMap { XlsxMapping.verticalAlign[$0] }
        let wrap = style["wrapMode"]?.stringValue == "wrap"
        if horizontal == nil && vertical == nil && !wrap { return "" }
        var out = "<alignment"
        if let horizontal { out += " horizontal=\"\(horizontal)\"" }
        if let vertical { out += " vertical=\"\(vertical)\"" }
        if wrap { out += " wrapText=\"1\"" }
        return out + "/>"
    }

    /// The leading number of a CSS length, so `"14px"` and `"14pt"` are both 14.
    static func leadingNumber(_ value: String) -> Double? {
        let digits = value.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let number = Double(digits), number.isFinite, number > 0 else { return nil }
        return number
    }

    func toXML() -> String {
        let numFmts = numberFormatXML.isEmpty
            ? ""
            : "<numFmts count=\"\(numberFormatXML.count)\">\(numberFormatXML.joined())</numFmts>"
        let dxfs = dxfXML.isEmpty
            ? "<dxfs count=\"0\"/>"
            : "<dxfs count=\"\(dxfXML.count)\">\(dxfXML.joined())</dxfs>"
        return "\(XlsxMapping.xmlDeclaration)<styleSheet xmlns=\"\(XlsxMapping.nsMain)\">\(numFmts)"
            + "<fonts count=\"\(fontXML.count)\">\(fontXML.joined())</fonts>"
            + "<fills count=\"\(fillXML.count)\">\(fillXML.joined())</fills>"
            + "<borders count=\"\(borderXML.count)\">\(borderXML.joined())</borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\""
            + " borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"\(xfXML.count)\">\(xfXML.joined())</cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/>"
            + "</cellStyles>\(dxfs)</styleSheet>"
    }
}
