# Feature: a spreadsheet is an `.xlsx`

Neutrino Sheets reads and writes real Excel workbooks. A spreadsheet in Drive is
`application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, its Drive file is named
`Budget.xlsx`, and Excel, LibreOffice and Google's editors open one directly (issue #127).

Before this change the app read and wrote the bespoke `application/x-neutrino-sheet` JSON. Since
every spreadsheet created by any client is now an `.xlsx`, that meant the app listed nothing at all
until the previous change pointed the listings at the `office` category — and then listed
spreadsheets it still would not open, showing *"Excel file · not supported yet"* on every row.

**The bespoke JSON is gone from this app.** Not migrated — there was nothing left to migrate —
simply no longer a format it reads, writes, lists or routes.

## Where the format lives

`NeutrinoOOXML`, the module in `neutrino_shared_ios` that Docs added for `.docx`. Its `Zip/` and
`XML/` layers were already general — the package manifest says so outright: *"NeutrinoOOXML
deliberately depends on nothing else here: it is a file format, not a client, and Sheets and Slides
need the same zip and XML plumbing for `.xlsx` and `.pptx`."* This change is the second half of that
sentence coming true, and it added no new dependency.

- `Xlsx/XlsxMapping.swift` — the correspondence between the workbook model and SpreadsheetML, in one
  place so the reader and the writer cannot drift apart silently.
- `Xlsx/XlsxWriter.swift`, `Xlsx/XlsxReader.swift` — the two halves of that mapping.
- `Xlsx/XlsxJSON.swift` — a `JSONValue`, because the codec's door is JSON (see below).
- `Xlsx/XlsxCodec.swift` — the public door, plus the `.xlsx` name helpers.

This is the Swift half of `web/apps/web/src/lib/ooxml/xlsx/{mapping,read,write}.ts`. **The two are
one wire format** — a spreadsheet written on a phone is opened on the web and the other way round —
so a change to either belongs in both, and both repositories assert `read(write(m)) == m` over a
workbook carrying one of everything.

## The JSON door, and why charts survive for free

`DocxCodec` speaks either the model or the stored JSON envelope. `XlsxCodec` speaks **only** the
stored `{"sheets":[…]}` envelope, and that is the single decision this change turns on.

`SheetFile`/`SheetData` already carry `UnknownFields`: every key the app does not model — charts,
conditional formats, `cfVariables`, anything a later web release adds — is preserved and written back
byte for byte. Keeping the envelope as the codec's boundary means that mechanism keeps working
untouched. The app decodes exactly the JSON it always did; only the layer below it changed. Charts
made on the web round-trip through a phone save without `NeutrinoOOXML` knowing what a chart is, and
without this app growing a typed chart model it would never read.

The alternative — converting `.xlsx` straight to `SheetFile` — would have put app types inside a
format module and needed a second preservation mechanism beside the one that already works.

## What OOXML cannot hold

Three things, each a bounded gap rather than a shrug, and all of them go to `customXml/item1.xml`
addressed by index — the same mechanism and the same rules as `docx/mapping.ts`:

- **Charts.** Neutrino has twenty chart types, annotations and trendlines; OOXML chart parts for
  those are a project of their own, and neither implementation writes one. Carried whole.
- **The conditional-format kinds OOXML has no operator for** — progress bars, status indicators,
  heat-map presets, theme tokens, variable references, and the one *condition* with no operator
  either (`dateIsPastDue`). An approximation is written for each, so Excel shows the cell as flagged;
  the extras entry restores the exact rule.
- **Small attributes with no home**: a table's Neutrino style id (the table itself is a real OOXML
  table), and `clip` as distinct from `overflow` (OOXML has `wrapText` and no third state).

Excel keeps `customXml/` parts across an edit, so a workbook that has been *through* Excel comes back
with its extras intact. One *edited* in Excel comes back with the indices no longer lining up, and
then the extras are dropped and the base content — which is all real OOXML — still reads. Full
fidelity is a Neutrino-to-Neutrino property; it cannot be anything else once another editor has had
the file.

## The `neutrino/model.json` part

A spreadsheet saved before the web's OOXML writer landed is an `.xlsx` carrying a `neutrino/model.json`
part: the OOXML beside it was a lossy projection, so the model won on open. Nothing writes that part
any more, and neither does this app — but `XlsxCodec.decode` still reads one, guarded by the same
FNV-1a digest `ooxmlContainer.ts` computes, byte for byte.

Ignoring it was the tempting simplification and is wrong: such a workbook would open lossily on the
phone while opening correctly on the web, which is the two clients disagreeing about one file.
Reading it and saving is what migrates it.

## Foreign parts

A workbook that has been through Excel can carry pivot tables, images, VML and charts. None are
written here, and dropping them on every save would make Neutrino the tool that quietly deletes your
pivot table. `LoadedWorkbook.sourcePackage` holds the package the session opened and hands it to
every save, which copies forward every part under `xl/` that this writer does not itself produce.

## What changed in the app

- `SheetItem` — one MIME type. `displayName` strips `.xlsx`; `duplicateName` puts it back on the end,
  because `Budget.xlsx copy` is a file the operating system no longer recognises. `isOfficeSpreadsheet`
  is gone, and so is the row subtitle that said a spreadsheet could not be opened.
- `SheetFile.decode(from:)`/`encoded(keeping:)` — the seam. Package bytes in, package bytes out, with
  `encodedJSON()` kept for the envelope the round-trip tests compare.
- `SheetContentService` — creates a real, empty, *encrypted* `.xlsx` immediately after the create,
  because `POST /drive/files` writes no content for an OOXML type at all. `encrypt` takes `Data`
  rather than `String`: a zip is not UTF-8 and would not survive the trip through one.
- `SheetsDriveService` — names new files `Title.xlsx` and re-applies the extension on rename;
  `fetchItem` judges a file by `SheetItem.isSpreadsheet` rather than by the shared link vocabulary,
  which stays deliberately more forgiving for the sake of links minted by clients that have not
  shipped this change.

## Known limits, shared with the web writer

- Shared formulas (`<f t="shared">`) are read as their own text where the master carries it and as
  empty where it does not. Deriving the rest means translating relative references. Those cells keep
  their cached value, so the spreadsheet reads correctly and re-saves as literals.
- Rich text runs inside a shared string collapse to their concatenated text; a cell here holds one
  style, not several.
- A number format that is not exactly one of the structured set is carried through verbatim as a
  `customFormat` rather than half-recognised into something that would render differently.
- Text that merely looks numeric (`0015`, `1e5`, `0x1f`) stays text. Leading zeros are the case that
  actually bites: a column of zip codes would otherwise lose its first digit.
