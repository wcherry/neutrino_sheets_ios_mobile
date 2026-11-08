# Neutrino Sheets for iOS

The iOS client for the spreadsheets in [Neutrino Drive](https://github.com/wcherry/neutrino). It
opens the same end-to-end encrypted workbooks the web app edits, in the same format, and saves them
back where the web app can read them. It has no storage, sign-in or encryption of its own.

It sits beside `neutrino_docs_ios_mobile`, `neutrino_notes_ios_mobile`,
`neutrino_slides_ios_mobile`, `neutrino_photos_ios_mobile` and the other Neutrino apps, and uses the
same `neutrino_shared_ios` package for account identity, the OAuth flow, the E2EE key lifecycle,
the sign-in screens, `.xlsx` plumbing and printing.

## Running it

```bash
scripts/run_simulator.sh                         # iPhone 17 Pro, latest OS, Debug
scripts/run_simulator.sh --device "iPad Pro 13-inch (M4)"
scripts/run_simulator.sh --reset --screenshot    # fresh install, then a PNG
scripts/run_simulator.sh --physical --console    # the paired device, attached to its output
```

The script regenerates the Xcode project from `project.yml` with XcodeGen, then builds, installs
and launches the app. `neutrino_shared_ios` is referenced by relative path, so the two repositories
have to sit side by side:

```
getneutrino.app/
├── neutrino_shared_ios/
└── neutrino_sheets_ios_mobile/   ← this repo
```

Tests:

```bash
xcodegen generate
xcodebuild -project NeutrinoSheets.xcodeproj -scheme NeutrinoSheets \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`scripts/deploy_testflight.sh` builds, signs and uploads to TestFlight. `project.yml` is the source
of truth for the version and build numbers.

## What is in it

Once you're signed in, the app is a Drive browser plus a spreadsheet editor:

- **Browse.** Home (with folders), Recent, Favorites, Shared, Offline and Trash, each listing
  filtered server-side to spreadsheets. Create, rename, move, duplicate, star, trash and restore.
- **View.** A virtualised UIKit grid with frozen headers, cell styles, borders, number formats,
  merged cells, column widths, row heights, and a tab bar for multi-sheet workbooks.
- **Edit.** A formula bar with a cell-reference box, a numeric keyboard row, and range selection
  with a live sum, count and average. Fill handle with series detection. Cut, copy and paste with
  styles and relative references rewritten. Undo and redo. Autosave on the interval set in
  Settings.
- **Format.** Font, size, bold, italic, strikethrough, text and fill colours, alignment, borders,
  wrap, number formats including custom ones, merge and unmerge, clear formatting, and the table
  style gallery.
- **Structure.** Insert, delete, resize, hide and show rows and columns. Freeze panes. Add,
  rename, colour, reorder, duplicate and delete tabs. Sort, per-column filters, and find and
  replace.
- **Print.** "Print…" and "Print Selection…" over AirPrint.
- **Offline.** The last copy of each opened workbook is kept encrypted on the device and opens
  read-only when the server can't be reached. A banner says when the app is offline.
- **Drive previews.** The app draws a workbook's Drive thumbnail from its first sheet, since the
  server only ever sees ciphertext.

There is no formula engine yet. Cells show the value the web app last calculated, and formulas
pasted on a phone recalculate the next time the workbook is opened on the web. That, along with
sync, version history, sharing, charts, conditional formatting and the rest, is tracked epic by
epic in [`agent_docs/road_map.md`](agent_docs/road_map.md).

## How it fits the platform

- **File format.** Every Neutrino spreadsheet is a real `.xlsx`, and that is the only format the app
  reads and writes. It opens and saves the file in place, keeping it valid for Excel and the web
  app. The Sheets mapping is in `NeutrinoSheets/Workbook/OOXML/`, over the zip and XML layers in
  `neutrino_shared_ios`'s `NeutrinoOOXML`. Parts the app doesn't model yet, such as charts, are
  carried through so saving from a phone never drops them.
- **Saving.** Every save sends the content version it was based on. If someone else saved first,
  the app asks you to reload or keep yours, and never overwrites silently.
- **Encryption.** Workbooks are encrypted on the device with the account's key, through
  `NeutrinoCrypto`. The app has no crypto of its own.
- **Identity.** The OAuth client is `neutrino-sheets-ios`, registered by a `neutrino` migration,
  and the Keychain prefix is `nsheet`. Neither may change or be reused.
- **Feature switches.** `NeutrinoSheets/Config/FeatureFlags.swift` turns shipped epics off in a
  build without unpicking them. Universal Links (`appLinks`) stay off until the site routes
  `/open/sheet/*` to this app.

## Layout

| Folder | What is in it |
|---|---|
| `NeutrinoSheets/Workbook/` | The workbook model and its pure logic: formats, fill, merge, sort, filters, find, clipboard, undo, structural shifts, `.xlsx` |
| `NeutrinoSheets/Grid/` | The grid: geometry, frozen panes, painting, headers, previews |
| `NeutrinoSheets/Views/` | SwiftUI screens: browser, editor, format bar, dialogs, settings |
| `NeutrinoSheets/Services/` | Drive, content load and save, key vault, devices, deep links |
| `NeutrinoSheets/Printing/` | This app's pages for the shared AirPrint support |
| `NeutrinoSheetsTests/` | Unit tests |
| `agent_docs/` | The roadmap and design plans |
