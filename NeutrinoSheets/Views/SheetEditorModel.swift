import Foundation
import Sodium
import os.log

// MARK: - SheetEditorModel

/// The state of one open workbook: what was loaded, what has changed, and what is being written.
///
/// Kept out of the view because two of its responsibilities are genuinely stateful and easy to get
/// wrong in a `View`'s `@State`:
///
/// - **The save chain.** Never two autosave PUTs in flight at once. The web app hit real body
///   truncation doing that (see `usePersistence`'s `saveChainRef`), and the same shape of bug on a
///   phone would silently drop an edit.
/// - **Conflict.** A 409 is a decision for the user, not something to retry into.
@MainActor
final class SheetEditorModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var file: SheetFile?
    @Published private(set) var info: SheetFileInfo?
    @Published var activeSheetIndex: Int = 0
    @Published var selection: CellAddress?

    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasUnsavedChanges = false
    @Published var loadError: String?
    @Published var saveError: String?
    /// Set when the server refused a save because the workbook moved on elsewhere. Surfaced to the
    /// user, never resolved silently — overwriting is not this app's decision to make.
    @Published var conflict: ConflictState?

    struct ConflictState: Identifiable {
        let id = UUID()
        /// The version the server holds now, when it could be recovered from the error body.
        let serverVersion: Int?
    }

    // MARK: - Dependencies

    private let item: SheetItem
    private var contentService: SheetContentService
    private weak var driveService: SheetsDriveService?

    // MARK: - Session state

    /// The workbook's DEK, held for the session so a save needs neither a re-fetch nor a re-unseal.
    private var dek: Bytes?
    /// The version the loaded content was read at, sent as `expectedContentVersion` on the next save
    /// and advanced by each successful one.
    private var contentVersion: Int?
    /// True until the plaintext the server seeded at create time has been replaced by ciphertext.
    private var needsInitialEncryption = false

    /// The chain every save links onto, so no two writes overlap. Awaiting the previous task before
    /// starting the next is the whole mechanism.
    private var saveChain: Task<Void, Never>?

    /// True between a save being queued and it starting to run.
    ///
    /// Used to coalesce: a save that has not begun yet will serialise whatever the workbook holds
    /// at the moment it does, so queueing a second one behind it would upload identical bytes
    /// twice. Without this, a single edit produces two PUTs — the timer's and the flush's.
    private var isSaveQueued = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoSheets",
                                category: "SheetEditorModel")

    // MARK: - Init

    init(item: SheetItem, contentService: SheetContentService, driveService: SheetsDriveService?) {
        self.item = item
        self.contentService = contentService
        self.driveService = driveService
    }

    /// Re-points the model at the environment's services.
    ///
    /// The view constructs this model in its `init`, where `@EnvironmentObject` is not yet readable,
    /// so it starts with a placeholder content service and no drive service. This is called from
    /// `.task`, before ``load()``, and is idempotent.
    func attach(contentService: SheetContentService, driveService: SheetsDriveService?) {
        self.contentService = contentService
        self.driveService = driveService
    }

    // MARK: - Derived

    var title: String { info?.name ?? item.name }

    /// Whether this account may write to the workbook. A spreadsheet shared read-only opens in a
    /// viewer, and every editing affordance is hidden rather than disabled-on-tap.
    var isEditable: Bool {
        FeatureFlags.cellEditing && (info?.isEditable ?? false)
    }

    var sheetNames: [String] {
        (file?.sheets ?? []).enumerated().map { index, sheet in
            sheet.name ?? "Sheet \(index + 1)"
        }
    }

    var activeSheet: SheetData? {
        guard let file, file.sheets.indices.contains(activeSheetIndex) else { return nil }
        return file.sheets[activeSheetIndex]
    }

    /// The cell the selection names, if it holds anything.
    var selectedCell: SavedCell? {
        guard let selection else { return nil }
        return activeSheet?.cells[selection.id]
    }

    // MARK: - Loading

    func load() async {
        guard !isLoading, file == nil else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let loaded = try await contentService.loadWorkbook(for: item.id)
            file = loaded.file
            info = loaded.info
            dek = loaded.dek
            contentVersion = loaded.info.contentVersion
            needsInitialEncryption = loaded.needsInitialEncryption
            activeSheetIndex = 0
            selection = CellAddress(column: 1, row: 1)

            // A brand-new spreadsheet is still holding the server's *plaintext* seed. Encrypting it
            // is the first thing to do, before the user can type anything into it — but through the
            // save chain, so it can never race a save triggered moments later by a fast edit.
            if needsInitialEncryption {
                logger.debug("load: id=\(self.item.id, privacy: .public) needs initial encryption")
                queueSave()
            }
        } catch {
            logger.error("load failed: \(error, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // MARK: - Editing

    /// Commits a literal value typed into a cell.
    ///
    /// Phase 1 edits **literals only**. `raw` and `value` are written to the same text, which is
    /// correct for a literal and deliberately wrong for a formula — there is no evaluator yet
    /// (Epic 15), so a formula typed here would be stored with a display value it does not produce.
    /// ``isFormula(_:)`` is what the editor uses to refuse that.
    ///
    /// Cells that end up empty are removed rather than stored blank, matching what the web app
    /// writes: an empty cell is an absent key, not a key holding "".
    func commitEdit(_ text: String, at address: CellAddress) {
        guard isEditable, var file, file.sheets.indices.contains(activeSheetIndex) else { return }
        var sheet = file.sheets[activeSheetIndex]

        var cell = sheet.cells[address.id] ?? SavedCell(id: address.id)
        let trimmed = text
        cell.raw = trimmed.isEmpty ? nil : trimmed
        cell.value = trimmed.isEmpty ? nil : trimmed

        if cell.isEmpty {
            sheet.cells.removeValue(forKey: address.id)
        } else {
            sheet.cells[address.id] = cell
        }
        file.sheets[activeSheetIndex] = sheet
        self.file = file
        hasUnsavedChanges = true
    }

    /// Whether text is a formula, which Phase 1 cannot evaluate.
    static func isFormula(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    // MARK: - Saving

    /// Queues a save behind whatever is already in flight.
    ///
    /// Every path into saving goes through here — the timer, the manual save, and the
    /// leaving-the-editor flush — because that is the only way to be sure two PUTs are never on the
    /// wire at once.
    func queueSave() {
        guard !isSaveQueued else { return }
        isSaveQueued = true
        let previous = saveChain
        saveChain = Task { [weak self] in
            await previous?.value
            await self?.performSave()
        }
    }

    /// Saves if anything has changed. The autosave timer calls this.
    func saveIfNeeded() {
        guard hasUnsavedChanges, conflict == nil else { return }
        queueSave()
    }

    /// Waits for every queued save to finish. Called when the editor is going away, so an edit made
    /// a moment before leaving is not lost.
    func flush() async {
        saveIfNeeded()
        await saveChain?.value
    }

    private func performSave() async {
        // Released here rather than at the end: from this point the save is reading current state,
        // so an edit that lands during the upload does need a save of its own.
        isSaveQueued = false
        guard let file, let dek, isEditable else { return }
        // A conflict is unresolved until the user says otherwise; saving over it is exactly what
        // must not happen.
        guard conflict == nil else { return }

        isSaving = true
        saveError = nil
        defer { isSaving = false }

        // Cleared *before* the request, not after: an edit made while the upload is in flight has
        // to leave the flag set, and clearing afterwards would swallow it.
        hasUnsavedChanges = false

        do {
            let result = try await contentService.save(file, to: item.id, dek: dek,
                                                       expectedContentVersion: contentVersion)
            contentVersion = result.contentVersion
            needsInitialEncryption = false
            driveService?.spreadsheetWasSaved(itemID: item.id, size: result.sizeBytes,
                                              modifiedAt: result.updatedAt,
                                              contentVersion: result.contentVersion)
            logger.debug("save succeeded: id=\(self.item.id, privacy: .public)")
        } catch let error as SheetContentError {
            hasUnsavedChanges = true
            if case .contentVersionConflict(let current) = error {
                logger.error("save conflict: id=\(self.item.id, privacy: .public)")
                conflict = ConflictState(serverVersion: current)
            } else {
                logger.error("save failed: \(error, privacy: .public)")
                saveError = error.localizedDescription
            }
        } catch {
            hasUnsavedChanges = true
            logger.error("save failed: \(error, privacy: .public)")
            saveError = error.localizedDescription
        }
    }

    // MARK: - Conflict resolution

    /// Throws away this device's edits and re-reads the server's copy.
    func reloadAfterConflict() async {
        conflict = nil
        file = nil
        hasUnsavedChanges = false
        await load()
    }

    /// Keeps this device's copy, overwriting whatever landed on the server.
    ///
    /// Done by dropping the version guard for one save: the point of `expectedContentVersion` is to
    /// stop an *unintended* overwrite, and this one is intended.
    func keepLocalCopyAfterConflict() {
        guard let serverVersion = conflict?.serverVersion else {
            // Without the server's version there is nothing to guard against, so the save goes
            // unguarded — which is what the user just asked for.
            contentVersion = nil
            conflict = nil
            queueSave()
            return
        }
        contentVersion = serverVersion
        conflict = nil
        queueSave()
    }
}
