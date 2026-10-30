import Foundation
import Sodium
import os.log
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoOOXML

// MARK: - SheetContentError

enum SheetContentError: LocalizedError {
    case noEncryptionKey
    /// This device holds an identity, but not the version this spreadsheet's DEK was sealed to.
    /// Named separately from `noEncryptionKey` because it sends the user somewhere else: not
    /// "import your key" but "this account rotated and this device is missing a version".
    case missingKeyVersion(Int)
    case encryptionFailed
    case decryptionFailed
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)
    /// The file exists but is not a native Neutrino spreadsheet — a raw `.xlsx`, say.
    case notASpreadsheet(mimeType: String?)
    case notFound
    /// The server refused the write because the workbook moved on since this device read it.
    /// `current` is the version the server holds now, when it could be recovered from the response.
    case contentVersionConflict(current: Int?)

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:  return "No encryption key found. Import your key before opening or creating spreadsheets."
        case .missingKeyVersion(let version):
            return "This spreadsheet needs encryption key version \(version), which this device does not have. Scanning the key code again will not help \u{2014} it carries one key. On the computer that holds your key, open Settings \u{203A} Encryption and back up your older keys, then reopen this app."
        case .encryptionFailed: return "Failed to encrypt the spreadsheet."
        case .decryptionFailed: return "Failed to decrypt the spreadsheet."
        case .notAuthenticated: return "You are not signed in."
        case .networkError:     return "A network error occurred. Please check your connection."
        case .serverError(let code): return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        case .notASpreadsheet:
            return "This file isn\u{2019}t a spreadsheet."
        case .notFound:         return "That spreadsheet is no longer available."
        case .contentVersionConflict:
            return "This spreadsheet changed on another device since it was opened. Reload to get the latest version, or keep your copy."
        }
    }
}

// MARK: - SealedFileKey

/// A spreadsheet's DEK as the server holds it: the sealed blob, and which of the caller's identity
/// versions it was sealed to.
///
/// The two travel together everywhere because they are only meaningful together. Passing the blob
/// alone is what let a rotated account's older spreadsheets fail to open — the caller had no way to
/// know which key to reach for, so it always reached for the newest.
struct SealedFileKey: Equatable {
    let sealed: String
    let keyVersion: Int

    init(sealed: String, keyVersion: Int) {
        self.sealed = sealed
        self.keyVersion = keyVersion
    }

    /// A ref written before versioning carries no version. Read as 1, which is what the server
    /// defaults `file_key_refs.key_version` to for the same rows.
    fileprivate init(_ response: APIKeyResponse) {
        self.sealed = response.encryptedFileKey
        self.keyVersion = response.keyVersion ?? 1
    }
}

// MARK: - SheetContentService

/// Encrypts, uploads, downloads, and decrypts the body of a spreadsheet.
///
/// Mirrors the E2EE protocol Neutrino Drive's endpoints expect exactly — XChaCha20-Poly1305
/// secretstream for the content, `crypto_box_seal` for the per-file key — so a workbook created here
/// is readable by the web app and vice versa. ``SheetsDriveService`` handles metadata (name, folder,
/// trash); this service handles the encrypted body.
///
/// ## Three checks the server no longer does
///
/// The drive refactor (`40842e2`) collapsed every per-app editor resource into generic Drive
/// endpoints, and in doing so moved three responsibilities to the client. None of them fails
/// loudly, which is why each is called out where it happens:
///
/// 1. **"Is this a spreadsheet?"** — `/info` answers for any file type. See ``fileInfo(for:)``.
/// 2. **Naive timestamps** — Drive serialises `2026-08-10T12:00:00` with no offset, meaning UTC.
///    Handled by `DriveDate`, which reads a zone-less timestamp as UTC rather than local.
/// 3. **The body of a new file** — an OOXML file is created with no content at all, because an
///    `.xlsx` is a zip the server has no business building. ``createSpreadsheet(name:parentID:body:)``
///    writes a real, sealed workbook straight after the create, and ``SheetFile/decode(from:)``
///    reads the gap in between as an empty workbook rather than an error.
///
/// ## What is never logged
///
/// No method here logs a DEK, a sealed DEK, plaintext, or a ciphertext fingerprint. File IDs and
/// byte counts are the most this will say about a workbook, because `os.log` messages persist in
/// the system log store and a key written there outlives the process that leaked it.
@MainActor
final class SheetContentService: ObservableObject {

    // MARK: - Dependencies

    /// Set once at app launch so the service can refresh tokens before requests.
    weak var authService: AuthService?

    /// Where the last copy of each opened workbook is kept, for opening read-only offline. Nil in
    /// tests that do not exercise it. Cleared on sign-out by the app.
    var offlineCache: OfflineFileCache?

    // MARK: - Private

    private static let sodium = Sodium()

    /// The secretstream header is 24 bytes and prefixes every ciphertext this app writes.
    private static let secretStreamHeaderSize = 24

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoSheets",
                                category: "SheetContentService")

    private let session: URLSession

    private var baseURL: String { AuthService.baseURL }

    private static let decoder: JSONDecoder = DriveDate.makeDecoder(convertFromSnakeCase: true)

    /// The multipart filename the web editor writes under. The server does not key off it, but
    /// matching keeps a Drive listing's "last write" indistinguishable between the two clients.
    private static let contentFileName = "sheet.json"

    // MARK: - Init

    /// - Parameter session: injected in tests as a `MockURLProtocol`-backed session.
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Create

    /// Creates a spreadsheet and returns it.
    ///
    /// `POST /drive/files` takes a *client-supplied* id, so the caller can open the editor on the id
    /// it generated without waiting for the response. The Docs app's older
    /// `POST /drive/files/upload` two-step is deliberately not followed here.
    ///
    /// The key is stored in a second call because the create endpoint has no field for it, and the
    /// body in a third. That is the same shape the web app uses: create, `PUT /files/{id}/key`,
    /// then autosave.
    ///
    /// The body cannot ride along in `initialContent`, which would be the obvious shortcut and is
    /// wrong: the server writes that field with `write_text_content`, verbatim and unencrypted.
    /// Putting ciphertext there would store Base64 *text* that no subsequent load could decrypt, and
    /// putting the package there would leave a copy of the original's contents in plaintext on the
    /// server. So the field is left nil and the real body goes up encrypted through autosave.
    ///
    /// - Parameter body: content to write instead of an empty workbook — used by Duplicate.
    func createSpreadsheet(name: String, parentID: String?,
                           body: SheetFile? = nil) async throws -> SheetItem {
        let id = UUID().uuidString
        logger.debug("createSpreadsheet: id=\(id, privacy: .public) parent=\(parentID ?? "root", privacy: .public)")
        let token = try await authorizedToken()

        let dek: Bytes = Self.sodium.secretStream.xchacha20poly1305.key()

        let request = APICreateFileRequest(id: id, name: XlsxCodec.withExtension(name),
                                           mimeType: SheetItem.sheetMIME, folderId: parentID)
        var urlRequest = try makeRequest(method: "POST", path: "/api/v1/drive/files", token: token)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await self.data(for: urlRequest)
        try Self.checkStatus(response, data: data)

        let created: APIFileResponse
        do {
            created = try Self.decoder.decode(APIFileResponse.self, from: data)
        } catch {
            throw SheetContentError.decodingError(underlying: error)
        }

        // A spreadsheet whose key ref failed to store is unreadable, so this is allowed to throw
        // rather than being fire-and-forget.
        try await storeFileKey(fileID: created.id, sealedFileKey: try sealDEK(dek), token: token)
        logger.debug("createSpreadsheet succeeded: id=\(created.id, privacy: .public)")

        var item = SheetItem(
            id: created.id, name: created.name, type: .file, parentID: created.folderId,
            size: created.sizeBytes, modifiedAt: created.updatedAt, isTrashed: false,
            mimeType: created.mimeType
        )
        item.contentVersion = created.contentVersion

        // Always written, even for a brand-new spreadsheet with no body of its own. `POST
        // /drive/files` creates an OOXML file with *no content at all* — an `.xlsx` is a zip the
        // server has no business building, and a seed it wrote would sit in object storage in the
        // clear — so this first save is what makes the file both a real workbook and an encrypted
        // one. Without it a new spreadsheet downloads as zero bytes, which Excel cannot open.
        do {
            // The DEK is carried over rather than re-fetched: the key was generated on this device
            // moments ago, and going back to `/files/{id}/key` for it would be a round trip to be
            // told something already known.
            let saved = try await save(body ?? .empty, to: item.id, dek: dek,
                                       expectedContentVersion: item.contentVersion)
            item.modifiedAt = saved.updatedAt
            item.size = saved.sizeBytes
            item.contentVersion = saved.contentVersion
        }
        return item
    }

    // MARK: - Load

    /// The result of opening a workbook.
    struct LoadedWorkbook {
        var file: SheetFile
        /// Held for the editing session so subsequent saves need neither a re-fetch nor a re-unseal.
        var dek: Bytes
        var info: SheetFileInfo
        /// True when the server still holds the plaintext body it seeded at create time, so the
        /// first save has to encrypt it. See ``loadWorkbook(for:)``.
        var needsInitialEncryption: Bool
        /// The `.xlsx` this session opened, kept so a save can carry forward the parts neither this
        /// app nor the web understands — a pivot table, an image, a chart Excel wrote. Nil when the
        /// stored body was not a package, which for a spreadsheet means it had no content yet.
        var sourcePackage: Data?
        /// When this device kept the copy that was opened, if it came from ``offlineCache`` because
        /// the server could not be reached. Such a workbook is opened read-only: an edit to it
        /// could not be saved, and would be written against a version that may be long gone.
        var offlineCopyDate: Date? = nil
    }

    /// Downloads, decrypts and decodes a workbook.
    ///
    /// The awkward case is a brand-new spreadsheet. `POST /drive/files` writes the default body as
    /// **plaintext**, before any client has generated a key for the file, and the first client save
    /// is what encrypts it. So a decryption failure here has two possible meanings, and telling them
    /// apart matters a great deal:
    ///
    /// - The DEK was *just generated* by this device (no key ref existed) — the bytes are the
    ///   server's plaintext seed. Read them as plaintext and re-save encrypted.
    /// - The DEK came from an existing key ref — the bytes are ciphertext this device cannot read.
    ///   Do **not** overwrite them. Whatever is wrong, replacing a file that cannot be decrypted
    ///   with an empty workbook would turn a recoverable fault into data loss.
    ///
    /// This mirrors `isNewEncryption` in the web app's `useEncryptedDocumentContent`.
    ///
    /// When the server cannot be reached at all, the copy this device kept the last time the
    /// workbook opened is returned instead, read-only — see ``LoadedWorkbook/offlineCopyDate``.
    func loadWorkbook(for fileID: String) async throws -> LoadedWorkbook {
        do {
            return try await loadWorkbookFromServer(fileID)
        } catch SheetContentError.networkError(let underlying) {
            guard let offline = try openOfflineCopy(of: fileID) else {
                throw SheetContentError.networkError(underlying: underlying)
            }
            logger.debug("loadWorkbook: id=\(fileID, privacy: .public) opened from the offline copy")
            return offline
        }
    }

    private func loadWorkbookFromServer(_ fileID: String) async throws -> LoadedWorkbook {
        logger.debug("loadWorkbook: id=\(fileID, privacy: .public)")

        guard let info = try await fileInfo(for: fileID) else { throw SheetContentError.notFound }
        guard info.isNativeSheet else {
            throw SheetContentError.notASpreadsheet(mimeType: info.mimeType)
        }

        let token = try await authorizedToken()
        let (dek, sealed) = try await resolveDEK(fileID: fileID, token: token)
        let isNewKey = sealed == nil
        let stored = try await fetchEncryptedContent(fileID: fileID, token: token)

        var needsInitialEncryption = false
        let plaintext: Data
        do {
            plaintext = try decrypt(data: stored, dek: dek)
        } catch {
            guard isNewKey else {
                logger.error("loadWorkbook: id=\(fileID, privacy: .public) will not decrypt with an existing key")
                throw SheetContentError.decryptionFailed
            }
            logger.debug("loadWorkbook: id=\(fileID, privacy: .public) holds plaintext seed content")
            needsInitialEncryption = true
            plaintext = stored
        }

        // Lenient by contract, not by accident: a spreadsheet created moments ago has no content at
        // all, and that is an empty workbook rather than an error. See `SheetFile.decode(from:)`.
        let file = SheetFile.decode(from: plaintext)
        logger.debug("loadWorkbook succeeded: id=\(fileID, privacy: .public) sheets=\(file.sheets.count)")
        // Only a body that is really sealed with a key the server holds is worth keeping: the
        // plaintext seed of a brand-new file is about to be replaced by its first save.
        if let sealed, !needsInitialEncryption {
            keepOfflineCopy(of: fileID, ciphertext: stored, sealed: sealed, info: info)
        }
        return LoadedWorkbook(file: file, dek: dek, info: info,
                              needsInitialEncryption: needsInitialEncryption,
                              sourcePackage: XlsxCodec.isWorkbook(plaintext) ? plaintext : nil)
    }

    /// Fetches the file's sealed DEK, generating and storing one if the file has none yet.
    ///
    /// Returns the existing sealed key, or nil when the key was newly generated — which is the
    /// only thing that makes reading a failed decryption as plaintext safe.
    private func resolveDEK(fileID: String, token: String) async throws -> (dek: Bytes, sealed: SealedFileKey?) {
        if let sealed = try await fetchSealedDEK(fileID: fileID, token: token) {
            return (try unsealDEK(sealed.sealed, keyVersion: sealed.keyVersion, fileID: fileID), sealed)
        }
        let dek: Bytes = Self.sodium.secretStream.xchacha20poly1305.key()
        try await storeFileKey(fileID: fileID, sealedFileKey: try sealDEK(dek), token: token)
        logger.debug("resolveDEK: generated a new key for id=\(fileID, privacy: .public)")
        return (dek, nil)
    }

    // MARK: - Offline copies

    /// The parts of ``SheetFileInfo`` an offline copy needs, in the cache's metadata slot.
    private struct CachedInfo: Codable {
        var id: String
        var name: String
        var sizeBytes: Int64
        var folderID: String?
        var mimeType: String?
        var updatedAt: Date
        var yourRole: String
        var contentVersion: Int?

        init(_ info: SheetFileInfo) {
            id = info.id
            name = info.name
            sizeBytes = info.sizeBytes
            folderID = info.folderID
            mimeType = info.mimeType
            updatedAt = info.updatedAt
            yourRole = info.yourRole.rawValue
            contentVersion = info.contentVersion
        }

        var info: SheetFileInfo {
            SheetFileInfo(id: id, name: name, sizeBytes: sizeBytes, folderID: folderID, mimeType: mimeType,
                          updatedAt: updatedAt, yourRole: ShareRole(serverValue: yourRole),
                          contentVersion: contentVersion)
        }
    }

    /// A workbook this device holds an offline copy of, for the Offline tab.
    struct OfflineCopy: Identifiable, Equatable {
        let info: SheetFileInfo
        let storedAt: Date
        var id: String { info.id }

        var item: SheetItem {
            SheetItem(id: info.id, name: info.name, type: .file, parentID: info.folderID,
                      size: info.sizeBytes, modifiedAt: info.updatedAt, isTrashed: false,
                      mimeType: info.mimeType, contentVersion: info.contentVersion,
                      isShared: info.yourRole != .owner)
        }
    }

    /// Every offline copy, most recently kept first.
    var offlineCopies: [OfflineCopy] {
        (offlineCache?.entries ?? []).compactMap { entry in
            guard let cached = try? JSONDecoder().decode(CachedInfo.self, from: entry.metadata) else { return nil }
            return OfflineCopy(info: cached.info, storedAt: entry.storedAt)
        }
    }

    /// Best effort: a copy that cannot be written is a missed convenience, not a failed open.
    private func keepOfflineCopy(of fileID: String, ciphertext: Data, sealed: SealedFileKey, info: SheetFileInfo) {
        guard let offlineCache, let metadata = try? JSONEncoder().encode(CachedInfo(info)) else { return }
        do {
            try offlineCache.store(fileID: fileID, ciphertext: ciphertext, sealedKey: sealed.sealed,
                                   keyVersion: sealed.keyVersion, metadata: metadata)
        } catch {
            logger.error("keepOfflineCopy: id=\(fileID, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// Brings an offline copy up to what a save just wrote, so the copy is never older than this
    /// device's own last edit. Only a workbook that already has a copy is refreshed.
    private func refreshOfflineCopy(of fileID: String, ciphertext: Data, result: SaveResult) {
        guard let entry = offlineCache?.entry(for: fileID),
              var cached = try? JSONDecoder().decode(CachedInfo.self, from: entry.metadata) else { return }
        cached.updatedAt = result.updatedAt
        cached.sizeBytes = result.sizeBytes
        cached.contentVersion = result.contentVersion
        keepOfflineCopy(of: fileID, ciphertext: ciphertext,
                        sealed: SealedFileKey(sealed: entry.sealedKey, keyVersion: entry.keyVersion),
                        info: cached.info)
    }

    /// Decrypts the kept copy with this device's own keys. Nil when there is none.
    ///
    /// No `fileID` is passed to the unseal, so a misfiled ref is not re-filed from here: that is a
    /// server write, and there is no server.
    private func openOfflineCopy(of fileID: String) throws -> LoadedWorkbook? {
        guard let (entry, ciphertext) = offlineCache?.copy(for: fileID),
              let cached = try? JSONDecoder().decode(CachedInfo.self, from: entry.metadata) else { return nil }
        let dek = try unsealDEK(entry.sealedKey, keyVersion: entry.keyVersion)
        let plaintext: Data
        do {
            plaintext = try decrypt(data: ciphertext, dek: dek)
        } catch {
            // Corrupt or from a key since rotated away: useless, and would fail the same way again.
            offlineCache?.remove(fileID: fileID)
            return nil
        }
        return LoadedWorkbook(file: SheetFile.decode(from: plaintext), dek: dek, info: cached.info,
                              needsInitialEncryption: false,
                              sourcePackage: XlsxCodec.isWorkbook(plaintext) ? plaintext : nil,
                              offlineCopyDate: entry.storedAt)
    }

    // MARK: - Save

    /// The outcome of a successful save: the server's own view of the workbook afterwards.
    struct SaveResult {
        let updatedAt: Date
        let sizeBytes: Int64
        /// The version the workbook is now at. Hold it and send it back on the next save.
        let contentVersion: Int?
    }

    /// Encrypts `file` with the workbook's DEK and PUTs it to the autosave endpoint.
    ///
    /// `expectedContentVersion` is the version this edit was written against. Passing it makes the
    /// server reject the write outright — as ``SheetContentError/contentVersionConflict(current:)``
    /// — if anything landed in between, which is the only way to close the gap between checking and
    /// writing. Passing nil saves unconditionally.
    ///
    /// `title` rides along in the optional `metadata` part, so a rename and a save are one request.
    /// The server applies it only after the content lands, and rejects the write outright if the
    /// file is in the trash.
    ///
    /// Note that autosave deliberately does *not* snapshot a version server-side; only an explicit
    /// `POST /versions` does (Epic 13).
    ///
    /// `keeping` is the package this save replaces — ``LoadedWorkbook/sourcePackage`` for the
    /// session — so a workbook that has been through Excel keeps the parts neither implementation
    /// models rather than being stripped by the first edit made on a phone.
    @discardableResult
    func save(_ file: SheetFile, to fileID: String, dek: Bytes,
              expectedContentVersion: Int? = nil, title: String? = nil,
              keeping previous: Data? = nil) async throws -> SaveResult {
        logger.debug("save: id=\(fileID, privacy: .public)")
        let token = try await authorizedToken()

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let ciphertext = try encrypt(data: try file.encoded(keeping: previous), dek: dek, xcss: xcss)

        // The autosave endpoint expects a multipart "file" part — sending raw bytes as
        // application/octet-stream trips actix-multipart's ContentTypeIncompatible check.
        var form = MultipartFormBody()
        form.appendFile(name: "file", fileName: Self.contentFileName,
                        mimeType: "application/octet-stream", data: ciphertext)
        if let title, let metadata = try? JSONEncoder().encode(["title": title]) {
            form.appendField(name: "metadata", value: String(decoding: metadata, as: UTF8.self))
        }

        var path = "/api/v1/drive/files/\(fileID)/autosave"
        if let expectedContentVersion {
            path += "?expectedContentVersion=\(expectedContentVersion)"
        }
        var request = try makeRequest(method: "PUT", path: path, token: token)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await upload(request, body: form.finalized())
        try Self.checkStatus(response, data: data)
        do {
            let updated = try Self.decoder.decode(APIFileResponse.self, from: data)
            logger.debug("save succeeded: id=\(fileID, privacy: .public)")
            let result = SaveResult(updatedAt: updated.updatedAt, sizeBytes: updated.sizeBytes,
                                    contentVersion: updated.contentVersion)
            refreshOfflineCopy(of: fileID, ciphertext: ciphertext, result: result)
            return result
        } catch {
            throw SheetContentError.decodingError(underlying: error)
        }
    }

    // MARK: - File info

    /// Metadata for one file, including the caller's role on it.
    ///
    /// **This is where "is it a spreadsheet?" is decided.** `/info` answers for every file type
    /// since the drive refactor — the endpoint no longer knows or cares that the caller wanted a
    /// spreadsheet — so nothing server-side will stop this app opening a `.xlsx` and rendering an
    /// empty grid. Callers read ``SheetFileInfo/isNativeSheet``.
    ///
    /// Returns nil when the file is gone (404) or not shared with this account (403) — both mean
    /// "not mine to read" rather than an error worth surfacing.
    func fileInfo(for fileID: String) async throws -> SheetFileInfo? {
        let token = try await authorizedToken()
        let request = try makeRequest(method: "GET",
                                      path: "/api/v1/drive/files/\(fileID)/info",
                                      token: token)

        let (data, response) = try await self.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 403 {
            logger.debug("fileInfo: id=\(fileID, privacy: .public) unavailable (\(http.statusCode))")
            return nil
        }
        try Self.checkStatus(response)
        do {
            return try SheetFileInfo.decoder.decode(SheetFileInfo.self, from: data)
        } catch {
            throw SheetContentError.decodingError(underlying: error)
        }
    }

    // MARK: - Crypto (internal, for unit testing)

    /// Encrypts `data` as `[24-byte header][ciphertext]` using an XChaCha20-Poly1305 secretstream.
    ///
    /// Takes bytes rather than text because a workbook is an `.xlsx` — a zip, which is not UTF-8 and
    /// would not survive being carried through a `String`.
    func encrypt(data: Data, dek: Bytes, xcss: SecretStream.XChaCha20Poly1305) throws -> Data {
        guard let stream = xcss.initPush(secretKey: dek) else { throw SheetContentError.encryptionFailed }
        let header = stream.header()
        guard let cipher = stream.push(message: Array(data), tag: .FINAL) else {
            throw SheetContentError.encryptionFailed
        }
        return Data(header + cipher)
    }

    /// Reverses ``encrypt(data:dek:xcss:)``.
    ///
    /// Returns `Data` rather than `String` because the caller has to be able to hand the *stored*
    /// bytes to the JSON decoder when decryption fails on a plaintext seed, and a lossy
    /// `String(decoding:)` in between would quietly mangle anything that was not UTF-8.
    func decrypt(data: Data, dek: Bytes) throws -> Data {
        guard data.count > Self.secretStreamHeaderSize else {
            logger.error("decrypt: data too short (\(data.count) bytes)")
            throw SheetContentError.decryptionFailed
        }
        let header = Array(data.prefix(Self.secretStreamHeaderSize))
        let ciphertext = Array(data.dropFirst(Self.secretStreamHeaderSize))
        let xcss = Self.sodium.secretStream.xchacha20poly1305
        guard let pull = xcss.initPull(secretKey: dek, header: header) else {
            logger.error("decrypt: initPull failed — wrong key length or corrupt header")
            throw SheetContentError.decryptionFailed
        }
        guard let (plaintext, _) = pull.pull(cipherText: ciphertext) else {
            logger.error("decrypt: authentication failed — wrong DEK or corrupted content")
            throw SheetContentError.decryptionFailed
        }
        return Data(plaintext)
    }

    /// Seals `dek` to the caller's **active** Curve25519 public key (`crypto_box_seal`), and
    /// reports which version that was.
    ///
    /// The version travels with the sealed key because the server records it on the key ref, and a
    /// ref that names the wrong version is a spreadsheet nothing can open: the web client reaches
    /// for the key the ref names, not the one it was actually sealed to.
    func sealDEK(_ dek: Bytes) throws -> SealedFileKey {
        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString) else {
            throw SheetContentError.noEncryptionKey
        }
        guard let sealed = Self.sodium.box.seal(message: dek, recipientPublicKey: Array(pubKeyData)),
              let b64 = Self.sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw SheetContentError.encryptionFailed
        }
        return SealedFileKey(sealed: b64, keyVersion: KeyImportService.activeKeyVersion())
    }

    /// Reverses ``sealDEK(_:)``, resolving `keyVersion` against the keys this device holds.
    ///
    /// `keyVersion` defaults to 1 because key refs written before rotation existed carry no
    /// version, and the server defaults the column to 1 for the same reason.
    ///
    /// A version this device lacks is reported as `missingKeyVersion` rather than as a decrypt
    /// failure. The distinction is the whole point of the versioning: the ciphertext is fine, the
    /// DEK is fine, and what is missing is one key that can still be brought across.
    ///
    /// The ref's version is tried first and every other key this device holds after it, because
    /// this app used to file its key under the vault's envelope version: on a rotated account its
    /// uploads were sealed to the active key and recorded as v1. When one opens under a different
    /// version and `fileID` is given, the ref is re-filed under the right one in the background.
    func unsealDEK(_ sealedBase64: String, keyVersion: Int = 1, fileID: String? = nil) throws -> Bytes {
        let opened: OpenedDEK
        do {
            opened = try KeyImportService.openSealedDEK(sealedBase64, keyVersion: keyVersion)
        } catch SealedDEKError.noKey {
            logger.error("unsealDEK: this device holds no encryption key")
            throw SheetContentError.noEncryptionKey
        } catch SealedDEKError.missingVersion(let version) {
            logger.error("unsealDEK: no key for version \(version, privacy: .public)")
            throw SheetContentError.missingKeyVersion(version)
        } catch {
            logger.error("unsealDEK: no key this device holds opens the seal (ref names v\(keyVersion, privacy: .public))")
            throw SheetContentError.decryptionFailed
        }
        if opened.isMisfiled, let fileID {
            refileKey(fileID: fileID, sealed: sealedBase64, version: opened.version)
        }
        return opened.dek
    }

    /// Re-files a key ref under the version that actually opens it — same sealed bytes, new number.
    /// Best effort: the DEK is already in hand, and a failure here is retried by the next open.
    private func refileKey(fileID: String, sealed: String, version: Int) {
        logger.info("refiling \(fileID, privacy: .public)'s key under v\(version, privacy: .public)")
        Task {
            guard let token = try? await authorizedToken() else { return }
            try? await storeFileKey(fileID: fileID,
                                    sealedFileKey: SealedFileKey(sealed: sealed, keyVersion: version),
                                    token: token)
        }
    }

    // MARK: - HTTP

    private func authorizedToken() async throws -> String {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw SheetContentError.notAuthenticated
        }
        return token
    }

    private func makeRequest(method: String, path: String, token: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw SheetContentError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request, retry: .default)
        } catch {
            throw SheetContentError.networkError(underlying: error)
        }
    }

    private func upload(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, from: body)
        } catch {
            throw SheetContentError.networkError(underlying: error)
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        try checkStatus(response, data: nil)
    }

    /// `data` is the response body, when the caller has it. A 409 is only reported as a version
    /// conflict when the body says so — Drive uses 409 for other things too, and treating those as
    /// "your edit is stale" would tell the user to reload over a fault reloading cannot fix.
    private static func checkStatus(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SheetContentError.serverError(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 409, let data, isContentVersionConflict(data) {
                throw SheetContentError.contentVersionConflict(current: currentVersion(fromErrorBody: data))
            }
            throw SheetContentError.serverError(statusCode: http.statusCode)
        }
    }

    /// Drive wraps errors as `{"error": {"code", "message"}}`.
    private static func isContentVersionConflict(_ data: Data) -> Bool {
        struct Envelope: Decodable { struct Body: Decodable { let code: String }; let error: Body }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return false }
        return envelope.error.code == "CONTENT_VERSION_CONFLICT"
    }

    /// The server states the version it holds in the conflict message. Recovering it saves a round
    /// trip when resolving, but it is a nicety — every caller tolerates nil.
    private static func currentVersion(fromErrorBody data: Data) -> Int? {
        struct Envelope: Decodable { struct Body: Decodable { let message: String }; let error: Body }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        guard let range = envelope.error.message.range(of: "found ") else { return nil }
        let digits = envelope.error.message[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Returns nil when the file has no key ref yet — a 404 here means "not encrypted *yet*", which
    /// is a normal state for a file the server created and nobody has opened.
    private func fetchSealedDEK(fileID: String, token: String) async throws -> SealedFileKey? {
        let request = try makeRequest(method: "GET", path: "/api/v1/drive/files/\(fileID)/key", token: token)
        let (data, response) = try await self.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try Self.checkStatus(response)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return SealedFileKey(try decoder.decode(APIKeyResponse.self, from: data))
        } catch {
            throw SheetContentError.decodingError(underlying: error)
        }
    }

    private func fetchEncryptedContent(fileID: String, token: String) async throws -> Data {
        let request = try makeRequest(method: "GET", path: "/api/v1/drive/files/\(fileID)", token: token)
        let (data, response) = try await self.data(for: request)
        try Self.checkStatus(response)
        return data
    }

    private func storeFileKey(fileID: String, sealedFileKey: SealedFileKey, token: String) async throws {
        var request = try makeRequest(method: "PUT",
                                      path: "/api/v1/drive/files/\(fileID)/key",
                                      token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `keyVersion` is sent, not left to the server's default of 1. Omitting it on a rotated
        // account files a spreadsheet sealed to v3 under v1, and every client — this one included
        // — then reaches for the wrong key and cannot open a file that is perfectly intact.
        request.httpBody = try JSONEncoder().encode(
            SetFileKeyBody(encryptedFileKey: sealedFileKey.sealed, keyVersion: sealedFileKey.keyVersion)
        )
        let (_, response) = try await data(for: request)
        try Self.checkStatus(response)
    }
}

// MARK: - API Models

private struct APICreateFileRequest: Encodable {
    let id: String
    let name: String
    let mimeType: String
    let folderId: String?
}

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let folderId: String?
    let sizeBytes: Int64
    let mimeType: String
    let updatedAt: Date
    /// Drive's optimistic-concurrency counter. Optional so a server that predates the field still
    /// decodes; a nil version just means the next save goes unguarded.
    let contentVersion: Int?
}

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
    /// Which of the caller's identity versions the DEK is sealed to. Optional so a server that
    /// predates versioning still decodes; `SealedFileKey` reads a missing value as 1, matching the
    /// column's own default.
    let keyVersion: Int?
}

/// `PUT /drive/files/{id}/key`. `keyVersion` says which entry of the caller's keyring the sealed
/// DEK belongs to, so a later read reaches for the right one.
private struct SetFileKeyBody: Encodable {
    let encryptedFileKey: String
    let keyVersion: Int
}

// MARK: - Data + Base64URL

extension Data {
    /// Decodes a Base64URL string (no padding), which is how Drive returns sealed keys.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}
