Neutrino Sheets for iOS — Feature Roadmap

Neutrino Sheets for iOS follows the same philosophy as the Neutrino Docs and Neutrino Notes iOS
apps: it is not a standalone spreadsheet, it is the iOS client for spreadsheets that already live in
Neutrino Drive. It invents no authentication, no storage, no encryption model and no sync protocol —
it reuses the platform the sibling apps already run on.

This roadmap assumes:

* Reuse the existing Neutrino Auth service and its browser-based login flow.
* Reuse Neutrino Drive as the storage layer (`?type=sheet` already filters listings server-side).
* Reuse the existing E2EE key model, key vault and key-import process.
* Speak the *same file format* as the web app — `sheet.json`, the `SheetFile` shape in
  `web/apps/web/src/app/(apps)/sheets/editor/types.ts` — byte-for-byte compatible in both directions.
* Follow the phased approach the Notes and Docs iOS roadmaps use, so the app is usable early.

⸻

What the web app actually does

Scoping this app means scoping against ~20k lines of TypeScript under
`neutrino/web/apps/web/src/app/(apps)/sheets/`. The surface, measured:

* **Grid** — cells addressed `A1`-style, per-cell style (font, size, weight, italic, strike, colour,
  fill, alignment, per-side borders, number format, decimals, custom format, wrap mode), merged
  cells (`colSpan`/`rowSpan`/`mergeAnchor`), per-column widths and per-row heights, multiple tabs
  per workbook with names and colours.
* **Formulas** — a hand-written evaluator (`editor/formula.ts`, 1341 lines) covering ~80 functions:
  `SUM AVERAGE COUNT COUNTA MIN MAX MEDIAN MOD ABS ROUND ROUNDUP ROUNDDOWN STDEV STDEV.P STDEV.S
  STDEVP`, `IF IFS IFERROR AND OR NOT`, `SUMIF SUMIFS COUNTIF COUNTIFS AVERAGEIF AVERAGEIFS`,
  `VLOOKUP HLOOKUP XLOOKUP INDEX MATCH OFFSET FILTER SORT SORTBY UNIQUE SEQUENCE RANDARRAY`,
  `LEFT RIGHT MID LEN FIND SEARCH SUBSTITUTE TRIM UPPER LOWER PROPER CONCAT CONCATENATE TEXTJOIN`,
  `TODAY NOW DATE DAY MONTH YEAR DATEDIF DATEADD TIMEADD EOMONTH NETWORKDAYS WORKDAY`,
  `PMT NPV IRR`. Cross-sheet references, a dependency graph, and precomputed display values.
* **Charts** — 18 types (`column bar line area pie donut scatter combo stacked-column stacked-bar
  stacked-column-100 stacked-bar-100 bubble histogram candlestick waterfall treemap sunburst`),
  axis config, data labels, markers, legends, themes, and a freehand annotation layer.
* **Conditional formatting** — 13 rule kinds (single colour, colour scale, data bar, icon set,
  duplicates/uniques, top/bottom, average, formula, progress bar, status indicator, heat map, theme
  colour, named variable), `stopIfTrue`, reusable variables and saved templates.
* **Structure** — insert/delete rows and columns with reference shifting (`structuralShift.ts`),
  sort, per-column filters, find & replace, table regions with a style gallery, templates picker.
* **Import / export** — CSV, XLSX and HTML export; CSV/XLSX import as a new sheet or a new tab;
  print. Raw `.xlsx` files opened and saved in place ("office mode"), with a one-shot convert to a
  native Neutrino sheet.
* **Server-side extras** — named ranges and the range-embed endpoint, presence, and AI. These are the
  only things still on `/api/v1/sheets`; see the API section below.

"Most of the functionality of the web app" is taken here to mean: the grid, styling, the formula
engine, structure editing, conditional formatting, charts (read + basic authoring), find/sort/filter,
export, sharing and version history. Real-time co-editing, the annotation layer and the AI panel are
deliberately late.

⸻

The API this app talks to

**There is no `/api/v1/sheets` CRUD resource.** It was removed in `40842e2`
(*refactor(drive): serve spreadsheets from generic drive endpoints*), which deleted `src/sheets/sheets/`
and dropped the `sheets` marker table. Every per-app editor service — docs, sheets, slides, drawing,
diagrams — collapsed into one set of generic Drive endpoints driven by a mime-type registry
(`src/drive/storage/native_types.rs`). **Membership in that registry is the marker**: a file is a
spreadsheet because its mime type is `application/x-neutrino-sheet`, not because a side table says so.

This is good news for this app. The Neutrino Docs iOS client already calls *only* generic Drive
endpoints — it never had a per-app resource — so the server has moved toward what the reference iOS
apps were already doing. The port is more direct than it would have been before the refactor.

Spreadsheet CRUD — all generic Drive:

| Operation | Endpoint |
| --- | --- |
| List | `GET /api/v1/drive/files?mimeType=application/x-neutrino-sheet&limit=200` |
| Create | `POST /api/v1/drive/files` — `{id, name, mimeType, folderId, initialContent?}` |
| Open (metadata) | `GET /api/v1/drive/files/{id}/info` — name, `yourRole`, `contentVersion`, `mimeType` |
| Read content | `GET /api/v1/drive/files/{id}` |
| Autosave | `PUT /api/v1/drive/files/{id}/autosave?expectedContentVersion=N` — multipart |
| Named version | `POST /api/v1/drive/files/{id}/versions` |
| Rename | `PATCH /api/v1/drive/files/{id}` — `{name}` |
| Convert from .xlsx | `POST /api/v1/drive/files/{id}/convert` — `{targetMimeType, content}` |

Still sheet-specific, still on `/api/v1/sheets`:

* `POST /api/v1/sheets/{id}/named-ranges`, `GET /api/v1/sheets/{id}/embed/{named_range_id}`
* `GET /api/v1/sheets/{id}/ws` — presence
* `POST /api/v1/sheets/{id}/ai/smart-fill|explore|pivot|insights`

Four consequences the iOS client has to get right, each verified against the new code:

1. **Create is one request, not two.** `POST /drive/files` takes a *client-supplied* id (so the app can
   navigate to the editor without waiting) and seeds the body itself. The web client is the model:
   generate a UUID, post it, open the editor. Do not follow the Docs app's older
   `POST /drive/files/upload` two-step.
2. **"Is this a spreadsheet?" is now a client-side check.** `/info` answers for any file type. The web
   adapter reads `mimeType` and synthesises its own 404 when it isn't a sheet — and that is
   load-bearing, because office mode keys off exactly that 404 to decide it must parse the file as
   `.xlsx`. iOS must reproduce the check, not assume the server does it.
3. **Timestamps come back naive.** Drive serialises `2026-08-10T12:00:00` with no offset, where the old
   sheets API returned RFC3339. The values are UTC. The web client appends `Z` before parsing; iOS
   must do the same, or every "Modified" time shifts by the device's UTC offset. **Check the copied
   `DriveDate.swift` handles an offset-less timestamp** — this is a silent, plausible-looking bug.
4. **The seeded default body is not the shape the editor writes.** A newly created sheet is seeded with
   `[{"index":"0","name":"Sheet1","celldata":[],"row":100,"column":26,…}]` — a FortuneSheet-shaped
   *array*, while the editor saves `{"sheets":[…]}`. The web editor survives this by reading
   `file.sheets ?? []` and starting empty. An iOS decoder that requires the `SheetFile` shape will fail
   to open every brand-new spreadsheet. Decode leniently and treat an unrecognised body as empty.

⸻

Vision

Phase 1 (MVP) — a secure, offline-capable spreadsheet viewer and cell editor for Neutrino Drive.
Users can log in, import keys, browse sheets, open them, edit cells and formulas, and sync.

Phase 2 — a real iOS spreadsheet editing experience: selection, fill, formatting, structure.

Phase 3 — synchronization, offline, version history and sharing at parity with Notes/Docs.

Phase 4 — formula-engine completeness and conditional formatting.

Phase 5 — charts.

Phase 6 — import/export and interop.

Phase 7 — native Apple ecosystem integration.

Phase 8 — collaboration and AI.

⸻

Architecture

Existing Neutrino services — reused, not reimplemented:

* Authentication (`/api/v1/auth/*`)
* Drive APIs — `?type=sheet` folder/recent/starred listings, the `mimeType=` filter on
  `GET /drive/files`, and the generic create / info / content / autosave / convert endpoints above
* Encryption / key-share APIs (`/drive/files/{id}/key`, `/key/share`)
* Sheets APIs — named ranges, embed, presence, AI (`/api/v1/sheets/{id}/…`)
* Version history, sharing, search, file-events relay

The Sheets app maintains **no separate backend**.

iOS components:

* **SwiftUI application** — auth, navigation, browser, settings
* **Grid layer** — a UIKit `UICollectionView`/`CADisplayLink` canvas hosted in SwiftUI. SwiftUI's own
  layout does not survive a 1000×26 cell viewport; this is the one place the app must drop to UIKit
* **Workbook model** — `SheetFile`/`SheetData`/`SavedCell` mirrored in Swift, `Codable`, round-tripping
  the web app's JSON exactly
* **Formula engine** — a Swift port of `formula.ts`: tokenizer, parser, evaluator, dependency graph
* **Encryption layer** — `KeyVaultService` + libsodium, Keychain storage, Face ID unlock
* **Local cache** — workbooks, metadata, sync queue, offline edits
* **Sync engine** — download, upload, retry queue, `contentVersion` conflict detection

⸻

Reuse from the sibling iOS apps

Neutrino Docs and Neutrino Notes already ship a platform layer that is near-identical between them —
a strong signal it will port a third time. **Copy these from `neutrino_docs_ios_mobile` (the more
complete of the two) and rename `NeutrinoDocs` → `NeutrinoSheets`, `com.neutrino.docs` →
`com.neutrino.sheets`.** All of them were checked and carry no `Doc*`-type dependencies:

| From `NeutrinoDocs/` | Notes |
| --- | --- |
| `Services/AuthService.swift` | Browser login, refresh, server-host override |
| `Services/KeychainService.swift` | |
| `Services/KeyVaultService.swift`, `KeyVaultCrypto.swift` | Byte-identical between Docs and Notes today |
| `Services/KeyImportService.swift`, `KeyQRDecryptService.swift` | JSON key file, paste, PIN-protected QR |
| `Services/BiometricAuthService.swift` | Face ID / Touch ID, app lock, auto-lock grace |
| `Services/DeviceIdentity.swift`, `DeviceSessionService.swift` | Device registration |
| `Services/NetworkMonitor.swift`, `MultipartFormBody.swift` | |
| `Services/DeepLinkRouter.swift` | Change the accepted kind from `.doc` to `.sheet` |
| `Models/NeutrinoAppLink.swift` | Already has a `.sheet` case — do not fork the vocabulary |
| `Models/DriveDate.swift`, `ShareRole.swift` | |
| `Views/LoginView.swift`, `KeyImportView.swift`, `KeyQRImportView.swift`, `QRScannerView.swift`, `VaultUnlockView.swift`, `LockScreenView.swift` | |
| `NeutrinoDocsTests/MockURLProtocol.swift`, `TestSupport.swift` | |

Adapted rather than copied — same shape, sheet-specific payloads: `DocsDriveService` →
`SheetsDriveService` (swap `?type=doc` for `?type=sheet`), `DocContentService` →
`SheetContentService` (same encrypt/upload/download path, `sheet.json` instead of the doc body),
`OfflineStore`, `SyncEngine`, `BackgroundSyncService`, `VersionHistoryService`, `SearchService`,
`AppSettings` (drop the Markdown editor preferences, add grid ones).

The Docs app already speaks only generic Drive endpoints, so its content service is now *closer* to
correct than it was before the drive refactor. Two deltas to apply while porting: use
`POST /drive/files` with a client-supplied id and let the server seed the body, rather than the Docs
app's `POST /drive/files/upload` two-step; and re-check `DriveDate.swift` against Drive's offset-less
timestamps (see consequence 3 above).

Build and release tooling — copy verbatim, changing only the scheme name:

* `project.yml` — xcodegen; drop the `swift-markdown` package (Sheets has no Markdown), keep
  `swift-sodium`. Bundle id `com.neutrino.sheets`, BGTask id `com.neutrino.sheets.sync`,
  `applinks:www.getneutrino.app` + `applinks:getneutrino.app`.
* `scripts/deploy_testflight.sh` — identical between Docs and Notes apart from `SCHEME`/`PROJECT`
  and the simulator name. Version bump → xcodegen → test → archive → export → verify the .ipa's
  signing profile and version → `altool` upload.
* `scripts/.env.example`, `.gitignore`.

⸻

Phase 1 — Core Platform

Goal: a secure shell that connects to the Neutrino ecosystem and can *read* a spreadsheet.

✅ Epic 1 — Application Shell

* ✅ SwiftUI app, xcodegen project, TestFlight deploy script
* ✅ Tabs: Home, Recent, Favorites, Shared, Offline, Settings
* ✅ Empty states — per-section copy and icon on `SheetsSection`. The Offline tab ships as an
  empty state only; its behaviour is Epic 12

Milestone: the app launches, navigates, and deploys to TestFlight.

⸻

✅ Epic 2 — Authentication

* ✅ Browser-based login (copied from Docs)
* ✅ Refresh tokens
* ✅ Logout
* ✅ Session persistence across restarts
* ✅ Device registration

Milestone: users stay signed in after an app restart.

⸻

✅ Epic 3 — Key Import & Encryption

* ✅ Import JSON key file
* ✅ Paste key
* ✅ Scan the PIN-protected QR code the web app shows
* ✅ Validate the key pair, store in Keychain, delete the temporary import file
* ✅ Face ID / Touch ID vault unlock

Milestone: the device can seal and unseal a file DEK.

⸻

✅ Epic 4 — Drive Integration

* ✅ Browse with `?type=sheet` — Home, Recent, Favorites, Shared, Trash, folder navigation
* ✅ Create a spreadsheet with `POST /api/v1/drive/files` — client-supplied UUID,
  `mimeType: application/x-neutrino-sheet`, server-seeded body. One request, and the editor can open
  before the response lands
* ✅ Create folder
* ✅ Rename (`PATCH /drive/files/{id}`), move, duplicate, delete, restore from Trash
* ✅ Favorites via Drive's `isStarred`

Note: Duplicate is create-then-autosave, not `initialContent`. The server writes that field with
`write_text_content` — verbatim and unencrypted — so ciphertext placed there would be stored as
Base64 *text* that no later load could decrypt, and plaintext there would leave the copy's contents
readable on the server.

Milestone: users organise spreadsheets exactly as they do on the web.

⸻

✅ Epic 5 — Workbook Model & Codec

The single highest-risk item after the formula engine: the format is the contract with the web app.

* ✅ `SheetFile` / `SheetData` / `SavedCell` / `CellStyle` as Swift `Codable` types
* ✅ Multi-tab workbooks: names, colours, order
* ✅ `colWidths` / `rowHeights` keyed by stringified 0-based index
* ✅ Merged cells: `colSpan`, `rowSpan`, `mergeAnchor`
* ✅ **Unknown-field preservation** — a phone must not silently drop `charts`,
  `conditionalFormats`, `cfVariables` or `tables` it cannot yet render when it saves. Round-trip
  them opaquely from day one, or the first mobile save destroys work done on the web
* ✅ **Lenient decode of the server-seeded default body** — a newly created file holds the
  FortuneSheet-shaped array from `native_types::EMPTY_SHEET_CONTENT`, not `{"sheets":[…]}`. Anything
  unrecognised decodes to an empty workbook, matching the web editor's `file.sheets ?? []`
* ✅ Round-trip fixtures generated from real web-app files, asserted byte-stable

Milestone: a workbook saved on iOS reopens on the web with nothing lost.

⸻

✅ Epic 6 — Read-Only Grid

`SavedCell.value` holds the precomputed display value, so a *viewer* ships before the formula engine
does. This is what makes an early, genuinely useful release possible.

* ✅ UIKit-backed virtualised grid, hosted in SwiftUI
* ✅ Frozen row/column headers, A1 addressing
* ✅ Cell styling: fonts, colours, fills, alignment, borders, wrap
* ✅ Number formats: number, currency, percent, date, time, datetime, decimals, custom
* ✅ Merged cells, column widths, row heights
* ✅ Tab bar for multi-sheet workbooks (read-only; authoring tabs is Epic 10)
* ⚠️ Pinch zoom and momentum scroll ship; **60fps on a 10k-cell sheet is not yet measured.** The
  work per frame is bounded by the viewport rather than the workbook — the canvas is
  viewport-sized and repositioned on scroll — but that is an argument, not a benchmark. Profile on
  a real device before the release

Milestone: any spreadsheet made on the web renders correctly and fast on a phone.

⸻

✅ Epic 7 — Content Load & Save

* ✅ `GET /api/v1/drive/files/{id}/info` for metadata, `yourRole` and `contentVersion`
* ✅ Client-side mime check — treat a file whose `mimeType` isn't `application/x-neutrino-sheet` as
  "not a native sheet", which is the signal office mode keys off (Epic 23)
* ✅ `GET /api/v1/drive/files/{id}` for content, decrypted with the file DEK
* ✅ Plaintext fallback for brand-new sheets — the server seeds plaintext default content at create
  time and the first client save encrypts it, same as the web app
* ✅ `PUT /api/v1/drive/files/{id}/autosave?expectedContentVersion=N`, multipart, encrypted. The
  optional `metadata` part carries `{"title":…}`, so a rename can ride along with a save; the server
  applies it only after the content lands, and rejects the write outright if the file is in trash
* ✅ 409 conflict surfaced to the user, never silently overwritten — Reload or Keep Mine, neither
  the default
* ✅ Serialised save chain — never two autosave PUTs in flight (the web app hit body truncation
  here). Queued saves also coalesce, so one edit cannot produce two identical PUTs
* ✅ Save on background/terminate
* ✅ `PATCH /api/v1/drive/files/{id}` for a standalone rename
* ✅ Normalise Drive's offset-less timestamps to UTC before parsing — the copied `DriveDate.swift`
  already reads a zone-less timestamp as UTC; asserted rather than assumed

Milestone: an edit made on the phone appears on the web.

⸻

Milestone 1 deliverable: log in, import keys, browse Drive, open any spreadsheet, read it correctly,
edit a cell's literal value, save. **Delivered** — 134 unit tests at the time, all passing; the
suite stands at 269 with Epics 8 and 9 in.

Two limits worth stating plainly:

* **Formulas are refused, not mangled.** Typing `=SUM(A1:A9)` shows an explanatory alert rather than
  saving. With no evaluator (Epic 15), a formula stored here would carry a `value` that is merely
  its own text, and the web app would then render that text where a number belongs. Refusing is the
  only option that cannot corrupt a shared file.
* **Editing a literal does not recalculate the formulas that depend on it.** The dependent cells keep
  the values the web app computed. Epic 15 is what makes this safe, and it is the reason cell editing
  is scoped to literals in Phase 1.

⸻

Phase 2 — Editing

Goal: an editing model that suits a touchscreen rather than a transplanted desktop one.

✅ Epic 8 — Cell Editing

* ✅ Tap to select, double-tap / Return to edit. The grid takes first responder on a tap, so a
  hardware keyboard drives it too — arrows move, shift-arrows extend, Tab steps right, Delete
  clears, ⌘C/X/V and ⌘Z work
* ✅ Formula bar with cell reference box. The box doubles as the range readout (`A1:C10`)
* ✅ Numeric keyboard accessory row (`= ( ) : , $ %` and arrows). The field is `UITextField` rather
  than SwiftUI's `TextField` for this: a symbol has to insert at the **caret**, and SwiftUI exposes
  no caret position — a SwiftUI field could only append. The arrows commit and step, which is what
  makes typing a column possible without touching the screen between cells
* ✅ Range selection by drag, with a live sum/count/average status bar. The drag is long-press-then-
  move rather than a pan: a pan would have to be arbitrated against the scroll view's own, and
  losing that argument is how a grid ends up unable to scroll. Holding without moving raises the
  edit menu instead. Dragging near an edge auto-scrolls
* ✅ Fill handle (drag to fill, series detection) — numbers (least-squares, so an uneven run still
  follows its trend), dates, months, weekdays, and text ending in digits (`Item 1` → `Item 2`).
  Excel's single-cell asymmetry is matched deliberately: a lone number repeats, a lone date advances
* ✅ Cut / copy / paste including styles and relative-reference rewriting. The block goes on the
  pasteboard twice — rich JSON under a private type, and TSV so other apps can read it — and paste
  prefers the rich payload. `encodeFormula` / `decodeFormula` are ported from the web app rather
  than reinvented, so a formula copied on a phone shifts the way the browser would shift it
* ✅ Undo / redo — per-cell patches, not snapshots. A snapshot of a 10k-cell tab per keystroke is
  megabytes of history for a two-character edit. Capped at the web app's `MAX_HISTORY` of 100
* ✅ Autosave on an interval from Settings

A third limit joins the two above, and it is the one that made paste and fill possible at all:

* **A pasted or filled formula keeps its references and loses its value.** Typing a formula is still
  refused, but propagating one that is already in the file is not the same act — refusing a paste
  because one cell in the block holds a formula would be worse than useless. So the references are
  rewritten and the *stale result is dropped*. The cell then shows its own formula text here, and
  recomputes the moment the workbook is opened on the web, which re-evaluates every formula on load
  (`evaluateSheetMap`). Carrying the source's value across is the one thing that would put a wrong
  number in a shared file.

⸻

✅ Epic 9 — Formatting

Every command is one `CellStylePatch` applied across the selection, through the same funnel Epic 8's
value edits use — so undo, the dirty flag and the save chain treat a fill colour exactly as they
treat a typed number. The patch type earns its existence in one place: the web app erases a style
field by spreading a key whose value is `undefined`, and a Swift patch of plain optionals cannot
tell that apart from "not in this patch". Every clear would have become a silent no-op, and "Clear
formatting" would have done nothing at all.

* ✅ Bold, italic, strikethrough, font size, font family. Un-bolding writes `"normal"` rather than
  removing the key, and the size is written in **points** (`"14pt"`) — the web app's dropdown reads
  it back by stripping `pt`, so a size stored any other way leaves its own toolbar blank
* ✅ Text colour, fill colour — a swatch palette plus an arbitrary-colour picker, always stored as
  `#rrggbb`. "Automatic" is offered separately from black: a cell with no colour follows Dark Mode,
  and one explicitly set to `#000000` does not
* ✅ Horizontal and vertical alignment, wrap mode
* ✅ Borders (per side, thin/medium/thick). The all-sides command clears the four per-side keys as
  well as setting `borderStyle` — a per-side value wins when the grid draws, so a stale one left
  behind is a border the user cannot get rid of
* ✅ Number formats and the custom-format dialog, ported from `CustomFormatDialog.tsx` including its
  apply rule: a typed pattern is looked up in the preset table, and a match brings its
  `numberFormat` and `decimalPlaces` with it while a date pattern *clears* the decimal count
* ✅ Merge / unmerge — one command, as on the web. Covered cells keep their values, so a merge
  followed by an unmerge is lossless; Excel discards them, and the format is the contract, not Excel
* ✅ Clear formatting. Values stay — clearing values is Epic 8's Delete, and the two are different
  intentions. A cell left holding neither is removed rather than stored as an id and nothing else
* ✅ Table style gallery and table regions — all 84 generated styles plus Blank, with the web app's
  ids reproduced exactly, because a `TableStyle.id` is written into every workbook that has a table
  in it and an id that drifted would simply stop being recognised

Two things this epic changed outside itself, both deliberate:

* **`tables` is now a typed field.** Epic 5 carried it opaquely; applying a table style means
  *writing* a region, not only preserving one. Claiming a key that used to be opaque is the one
  migration `UnknownFields` is built to survive — and a `tables` value in a shape this app cannot
  read still falls back to the opaque path, so it is written out again rather than dropped.
* **Undo carries table regions.** A `WorkbookEdit` now holds a tab's whole region list before and
  after, for the edits that change it. Without that, undoing a table style would put the cells back
  and leave the workbook still claiming a table.

⸻

⬜ Epic 10 — Structure

* ⬜ Insert / delete rows and columns, with reference shifting matching `structuralShift.ts`
* ⬜ Resize columns and rows by drag
* ⬜ Hide / show
* ⬜ Freeze panes
* ⬜ Add / rename / colour / reorder / duplicate / delete sheet tabs
* ⬜ Sort a range or a column
* ⬜ Per-column filters
* ⬜ Find & replace

Milestone: a spreadsheet can be built from scratch on a phone.

⸻

Phase 3 — Sync, Offline, History, Sharing

Mirrors what Notes and Docs already shipped; the services port with the payload swapped.

⬜ Epic 11 — Sync Engine

* ⬜ Background upload / download via `BGTaskScheduler`
* ⬜ Retry queue
* ⬜ Conflict detection on `contentVersion`
* ⬜ Live updates over `GET /api/v1/files/{id}/ws` — the relay carries a signal, never content, so
  the workbook is re-read and decrypted on-device. Offered mid-edit, never applied

⬜ Epic 12 — Offline

* ⬜ Make available offline
* ⬜ Edit offline, queue changes, drain on reconnect
* ⬜ Cache recents and favorites

⬜ Epic 13 — Version History

* ⬜ List previous versions with timestamps
* ⬜ Restore a version
* ⬜ Save a named version — Drive's autosave endpoint does not snapshot, so an explicit save is what
  gives the other two anything to work with

⬜ Epic 14 — Sharing & Permissions

* ⬜ Share a spreadsheet: the permission grant **plus** the DEK re-wrapped on-device for the
  recipient's public key (`POST /drive/files/{id}/key/share`) — without it the recipient gets a file
  they cannot decrypt
* ⬜ Viewer / commenter / editor roles, changed and revoked from the share sheet
* ⬜ Shared-with-me section; open read-only unless `GET /files/{id}/info` reports an editable role
* ⬜ Shared folders, including re-sharing folder contents
* ⬜ Public share links — **not planned.** Drive's link endpoints serve stored bytes, which for an
  encrypted sheet is ciphertext with no key ref. Same hole the web app has

⸻

Phase 4 — Formulas & Conditional Formatting

⬜ Epic 15 — Formula Engine

The largest single work item in this roadmap. It must agree with `formula.ts` *exactly* — a
divergence does not fail loudly, it writes a different number into a shared file.

* ⬜ Tokenizer, parser, evaluator
* ⬜ Cell / range / cross-sheet references, absolute and relative
* ⬜ Dependency graph, topological recalculation, circular-reference detection
* ⬜ Error values (`#DIV/0!`, `#REF!`, `#VALUE!`, `#N/A`, `#NAME?`)
* ⬜ Math & stats: `SUM AVERAGE COUNT COUNTA MIN MAX MEDIAN MOD ABS ROUND ROUNDUP ROUNDDOWN STDEV
  STDEV.P STDEV.S STDEVP`
* ⬜ Logic: `IF IFS IFERROR AND OR NOT`
* ⬜ Conditional aggregates: `SUMIF SUMIFS COUNTIF COUNTIFS AVERAGEIF AVERAGEIFS`
* ⬜ Lookup & arrays: `VLOOKUP HLOOKUP XLOOKUP INDEX MATCH OFFSET FILTER SORT SORTBY UNIQUE SEQUENCE
  RANDARRAY`
* ⬜ Text: `LEFT RIGHT MID LEN FIND SEARCH SUBSTITUTE TRIM UPPER LOWER PROPER CONCAT CONCATENATE
  TEXTJOIN`
* ⬜ Dates: `TODAY NOW DATE DAY MONTH YEAR DATEDIF DATEADD TIMEADD EOMONTH NETWORKDAYS WORKDAY`
* ⬜ Finance: `PMT NPV IRR`
* ⬜ Autocomplete and the function helper
* ⬜ **Differential test suite** — the same fixture workbook evaluated by `formula.ts` and by the
  Swift port, asserted cell-for-cell. Non-negotiable; nothing else catches drift

⬜ Epic 16 — Conditional Formatting

* ⬜ Rendering all 13 rule kinds: single colour, colour scale, data bar, icon set,
  duplicates/uniques, top/bottom, average, formula, progress bar, status indicator, heat map, theme
  colour, named variable
* ⬜ `stopIfTrue` ordering
* ⬜ Rule authoring UI
* ⬜ Named variables and saved templates

⬜ Epic 17 — Named Ranges

* ⬜ Create against `POST /api/v1/sheets/{id}/named-ranges` — one of the three things that survived
  the drive refactor and is still sheet-specific
* ⬜ Use in formulas
* ⬜ Range embed via `GET /api/v1/sheets/{id}/embed/{named_range_id}`, which returns a 2-D array of
  display values

⸻

Phase 5 — Charts

Swift Charts covers the common types; the rest need a `Canvas` renderer. Rendering ships before
authoring, and authoring ships before annotation.

⬜ Epic 18 — Chart Rendering

* ⬜ Core: column, bar, line, area, pie, donut, scatter, combo
* ⬜ Stacked: stacked-column, stacked-bar, and both 100% variants
* ⬜ Advanced: bubble, histogram, candlestick, waterfall, treemap, sunburst
* ⬜ Axis config, data labels, markers, legends, chart themes

⬜ Epic 19 — Chart Authoring

* ⬜ Create from a selected range
* ⬜ Change type, series and range
* ⬜ Move and resize on the sheet
* ⬜ Export a chart as an image

⬜ Epic 20 — Chart Annotations

* ⬜ Callouts, notes, arrows, shapes, text

⸻

Phase 6 — Import, Export & Interop

⬜ Epic 21 — Export

* ⬜ CSV
* ⬜ XLSX
* ⬜ HTML
* ⬜ PDF and AirPrint
* ⬜ iOS share sheet

⬜ Epic 22 — Import

* ⬜ CSV as a new sheet or a new tab
* ⬜ XLSX as a new sheet or a new tab
* ⬜ Open from Files / share-sheet inbound

⬜ Epic 23 — Office Mode

* ⬜ Open a raw `.xlsx` from Drive and edit it in place, keeping the bytes valid OOXML at rest
* ⬜ "Convert to Neutrino Sheet" via `POST /api/v1/drive/files/{id}/convert` with
  `{targetMimeType: "application/x-neutrino-sheet", content}` — this replaced the per-app promote
  endpoint. The server validates the conversion against `native_types::can_convert`, so only a real
  `.xlsx` is accepted, and the file keeps its id
* ⚠️ There is no SheetJS on iOS. This epic needs a Swift XLSX reader/writer (or a vendored C
  library) and is the reason it sits this late — it is a dependency decision, not a UI one

⬜ Epic 24 — Templates

* ⬜ The web app's template picker set, from `editor/templates/sheetTemplates.ts`

⸻

Phase 7 — Native iOS Experience

⬜ Epic 25 — Universal Links

* ⬜ Accept `https://www.getneutrino.app/open/sheet/<file id>`
* ⚠️ **Requires a server change.** `neutrino/static/apple-app-site-association` currently routes
  `/open/sheet/*` to `com.neutrino.drive` with the comment "No Sheets iOS app yet". Shipping this app
  means moving that pattern to `com.neutrino.sheets` in both that file and the Drive repo's
  `deploy/apple-app-site-association`. Sequence it with the App Store release, not before

⬜ Epic 26 — iPad

* ⬜ Keyboard shortcuts and hardware-keyboard cell navigation
* ⬜ Trackpad and pointer support
* ⬜ Multi-window and Stage Manager
* ⬜ Drag & drop
* ⬜ External display

⬜ Epic 27 — System Integration

* ⬜ Widgets: recent sheets, a pinned range
* ⬜ Spotlight indexing of titles
* ⬜ Siri Shortcuts: new sheet, append row
* ⬜ Handoff

⬜ Epic 28 — Search

* ⬜ On-device index over titles and cell text
* ⬜ Server search across Drive with filters
* ⬜ Saved searches

⬜ Epic 29 — App Lock

* ⬜ Opt-in Face ID / Touch ID lock with an auto-lock grace period and an app-switcher privacy
  shield (`BiometricAuthService` + `LockScreenView`, copied from Docs). This protects the *screen* —
  the data is already end-to-end encrypted

⸻

Phase 8 — Collaboration & AI

⬜ Epic 30 — Presence

* ⬜ Connect to `GET /api/v1/sheets/{id}/ws`
* ⬜ Show who else is in the workbook and which cell they are on
* ⬜ Remote cell updates applied live

⬜ Epic 31 — Comments

* ⬜ Cell comments, threads, resolve, mentions
* ⚠️ Blocked on the same question Notes hit: comment bodies are stored **plaintext** server-side, and
  a comment on an E2EE spreadsheet is spreadsheet content. A product decision, not an implementation
  one

⬜ Epic 32 — AI

* ⬜ Smart fill (`POST /{id}/ai/smart-fill`)
* ⬜ Explore panel (`/ai/explore`)
* ⬜ Pivot suggestions (`/ai/pivot`)
* ⬜ Insights (`/ai/insights`)

⬜ Epic 33 — Real-time co-editing

* ⬜ Live cursors, live editing, conflict resolution

⸻

Cross-cutting

Performance

* ⬜ Virtualised grid rendering; nothing off-screen laid out
* ⬜ Incremental recalculation — only the dependency subtree of an edited cell
* ⬜ Parse and evaluate off the main actor
* ⬜ Fast startup (<2s)

Security

* ⬜ End-to-end encryption for every byte of workbook content
* ⬜ Keychain / Secure Enclave key storage
* ⬜ Face ID / Touch ID unlock, automatic lock after inactivity
* ⬜ Secure clipboard handling

Accessibility

* ⬜ VoiceOver over the grid — cell coordinates and values announced together
* ⬜ Dynamic Type, high contrast, reduced motion
* ⬜ Full keyboard navigation

Quality

* ⬜ Unit tests per service, mirroring `NeutrinoDocsTests` (`MockURLProtocol` + `TestSupport`)
* ⬜ Format round-trip fixtures
* ⬜ Differential formula tests against the TypeScript engine
* ⬜ Snapshot tests for grid rendering and number formatting
* ⬜ Offline synchronization tests

⸻

Recommended Milestones

| Milestone | Deliverable |
| --- | --- |
| M1 | Auth, keys, Drive browsing, workbook codec, read-only grid, cell edit + save (Phase 1) |
| M2 | Full touch editing: selection, fill, formatting, structure, sort/filter/find (Phase 2) |
| M3 | Sync, offline, version history, sharing (Phase 3) |
| M4 | Formula engine at parity, conditional formatting, named ranges (Phase 4) |
| M5 | Charts — rendering, then authoring (Phase 5) |
| M6 | Import/export, office mode, templates (Phase 6) |
| M7 | Universal Links, iPad, widgets, Spotlight, search, app lock (Phase 7) |
| M8 | Presence, comments, AI, real-time co-editing (Phase 8) |

⸻

MVP Success Criteria

The MVP is complete when a user can:

* ✅ Log in using the existing Neutrino authentication flow
* ✅ Import and securely store E2EE keys using the same process as Neutrino Drive
* ✅ Browse their spreadsheets in Neutrino Drive
* ✅ Create, rename, move, duplicate and delete spreadsheets
* ✅ Open any spreadsheet made on the web and see it render correctly — styles, number formats,
  merges, multiple tabs
* ⚠️ Edit cell **values** — typing, range selection, fill, cut/copy/paste, undo/redo, autosave
  back to Drive. Typing a formula is refused until Epic 15; a pasted or filled one keeps its
  references and drops its stale value, and recomputes when the sheet is next opened on the web
* ✅ Encrypt all content before upload and decrypt it locally after download
* ✅ Save without ever destroying charts, conditional formats or table regions the phone cannot yet
  render
* ⬜ Work offline, with changes syncing when connectivity returns — Phase 3, Epic 12
* ⬜ Reach version history through the existing Drive APIs — Phase 3, Epic 13

⸻

Risks

1. **Formula-engine divergence.** Two independent implementations of ~80 functions over one shared
   file. Mitigated only by the differential test suite in Epic 15 — treat it as part of the epic, not
   as follow-up work.
2. **Grid performance.** SwiftUI cannot carry this. Committing to a UIKit-backed grid in Epic 6 is a
   deliberate architectural choice, and retrofitting it later would be a rewrite.
3. **Destructive saves.** The phone will always understand less of the format than the web app does.
   Opaque preservation of unknown fields (Epic 5) has to land before the first save ships.
4. **Quiet API-contract bugs.** The drive refactor moved three checks from the server to the client:
   the mime-type test that decides a file is a spreadsheet, UTC normalisation of naive timestamps, and
   tolerance of a seeded default body in a different shape. None of them fail loudly — they show a
   404, a time three hours off, or an empty grid. Each needs a test, not a careful reading.
5. **XLSX on iOS.** No equivalent of SheetJS. Epic 21/22/23 rest on a dependency decision that should
   be made early even though the work lands late.
6. **AASA ownership.** `/open/sheet/*` belongs to Drive today. Moving it is a coordinated release
   across two repos and the App Store — plan it, don't discover it.
