// MARK: - FeatureFlags

/// Compile-time switches for the Phase 1 feature set (see `agent_docs/road_map.md`).
///
/// Every flag for a shipped epic defaults to `true`. They exist so a feature can be switched off in
/// a build without unpicking its wiring, which is how the sibling Neutrino apps shipped their
/// epics. Flags for epics that have not been written yet are absent rather than `false` — a flag
/// guarding code that does not exist reads as though the feature is one toggle away.
enum FeatureFlags {

    // MARK: - Phase 1

    /// Epic 4 — Drive integration: browsing Home / Recent / Favorites / Shared / Trash, folder
    /// navigation, and the create / rename / delete / move / duplicate / star operations.
    static let driveIntegration: Bool = true

    /// Epic 3 — importing the encryption key by scanning the PIN-protected QR code the web app
    /// shows, alongside the key-file and paste paths. Requires `NSCameraUsageDescription`.
    static let qrKeyScan: Bool = true

    /// Epic 3 / Epic 29 — Face ID / Touch ID unlock for the app and for encryption-key access.
    static let biometricLock: Bool = true

    /// Epic 6 — the read-only grid: virtualised rendering, styling, number formats, merges, and the
    /// multi-tab bar.
    static let grid: Bool = true

    /// Epic 7 / Epic 8 — editing a cell's literal value and saving it back to Drive.
    ///
    /// Switching this off leaves a viewer, which is a genuinely useful build: `SavedCell.value`
    /// carries the web app's pre-computed display values, so a workbook renders correctly without
    /// anything here being able to change it.
    static let cellEditing: Bool = true

    // MARK: - Phase 2

    /// Epic 9 — cell formatting: the format bar, the format sheet, borders, number formats, merge
    /// and the table-style gallery.
    ///
    /// Switching this off leaves Epic 8's editor: values can still be typed, filled and pasted, and
    /// the workbook's existing styles still render. It does not switch editing *on* — every
    /// formatting command goes through the same guard a value edit does, so a read-only share and a
    /// build with ``cellEditing`` off are both unaffected by this flag.
    static let formatting: Bool = true

    /// Epic 10 — structure: insert and delete rows and columns, resize, hide and show, freeze
    /// panes, the tab operations, sort, per-column filters and find & replace.
    ///
    /// Switching this off leaves Epics 8 and 9 — a workbook's cells can still be edited and
    /// formatted, and a workbook whose rows were inserted on the web still opens correctly, because
    /// nothing here changes how a file is read. Like ``formatting``, it does not switch editing
    /// *on*: every command behind it goes through the same `isEditable` guard a typed value does.
    static let structure: Bool = true

    /// Printing the sheet, or the selection, over AirPrint from the actions menu. The pages are laid
    /// out by NeutrinoPrint in neutrino_shared_ios; see `SheetPrint`.
    static let printing: Bool = true

    /// Epic 25 — accepting inbound `https://www.getneutrino.app/open/sheet/<id>` Universal Links.
    ///
    /// Off, and deliberately: the deployed `apple-app-site-association` still routes `/open/sheet/*`
    /// to `com.neutrino.drive`, so iOS does not hand those links to this app. The router and the
    /// entitlement are in place, so turning this on is one line — but it has to be sequenced with
    /// the AASA change in both server repos *and* the App Store release, or links break for users
    /// who have Drive installed and this app not.
    static let appLinks: Bool = false
}
