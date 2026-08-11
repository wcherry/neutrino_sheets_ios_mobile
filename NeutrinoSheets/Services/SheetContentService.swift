import Foundation
import Sodium
import os.log

// MARK: - SheetContentError

enum SheetContentError: LocalizedError {
    case noEncryptionKey
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
        case .encryptionFailed: return "Failed to encrypt the spreadsheet."
        case .decryptionFailed: return "Failed to decrypt the spreadsheet."
        case .notAuthenticated: return "You are not signed in."
        case .networkError:     return "A network error occurred. Please check your connection."
        case .serverError(let code): return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        case .notASpreadsheet:
            return "This file isn\u{2019}t a Neutrino spreadsheet. Opening Excel files on iOS is not supported yet."
        case .notFound:         return "That spreadsheet is no longer available."
        case .contentVersionConflict:
            return "This spreadsheet changed on another device since it was opened. Reload to get the latest version, or keep your copy."
        }
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
/// 3. **The seeded default body** — a new file holds a FortuneSheet-shaped *array*, not
///    `{"sheets":[…]}`. Handled by ``SheetFile/decode(from:)``.
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
    /// **One request, not two.** `POST /drive/files` takes a *client-supplied* id and seeds the body
    /// itself from the mime-type registry, so the create and the first content write are a single
    /// round trip — and the caller can open the editor on the id it generated without waiting for
    /// the response. The Docs app's older `POST /drive/files/upload` two-step is deliberately not
    /// followed here.
    ///
    /// The key is stored in a second call because the create endpoint has no field for it. That is
    /// the same shape the web app uses: create, then `PUT /files/{id}/key`.
    ///
    /// - Parameter body: content to write instead of leaving the server's default — used by
    ///   Duplicate.
    ///
    ///   It is written by a *second* request rather than through `initialContent`, which would be
    ///   the obvious shortcut and is wrong: the server writes that field with `write_text_content`,
    ///   verbatim and unencrypted. Putting ciphertext there would store Base64 *text* that no
    ///   subsequent load could decrypt, and putting the JSON there would leave a copy of the
    ///   original's contents in plaintext on the server. So the field is left nil, the file is
    ///   created with the seeded default, and the real body goes up encrypted through autosave.
    func createSpreadsheet(name: String, parentID: String?,
                           body: SheetFile? = nil) async throws -> SheetItem {
        let id = UUID().uuidString
        logger.debug("createSpreadsheet: id=\(id, privacy: .public) parent=\(parentID ?? "root", privacy: .public)")
        let token = try await authorizedToken()

        let dek: Bytes = Self.sodium.secretStream.xchacha20poly1305.key()

        let request = APICreateFileRequest(id: id, name: name, mimeType: SheetItem.sheetMIME,
                                           folderId: parentID)
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
        try await storeFileKey(fileID: created.id, encryptedFileKey: try sealDEK(dek), token: token)
        logger.debug("createSpreadsheet succeeded: id=\(created.id, privacy: .public)")

        var item = SheetItem(
            id: created.id, name: created.name, type: .file, parentID: created.folderId,
            size: created.sizeBytes, modifiedAt: created.updatedAt, isTrashed: false,
            mimeType: created.mimeType
        )
        item.contentVersion = created.contentVersion

        if let body {
            // The DEK is carried over rather than re-fetched: the key was generated on this device
            // moments ago, and going back to `/files/{id}/key` for it would be a round trip to be
            // told something already known.
            let saved = try await save(body, to: item.id, dek: dek,
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
    func loadWorkbook(for fileID: String) async throws -> LoadedWorkbook {
        logger.debug("loadWorkbook: id=\(fileID, privacy: .public)")

        guard let info = try await fileInfo(for: fileID) else { throw SheetContentError.notFound }
        guard info.isNativeSheet else {
            throw SheetContentError.notASpreadsheet(mimeType: info.mimeType)
        }

        let token = try await authorizedToken()
        let (dek, isNewKey) = try await resolveDEK(fileID: fileID, token: token)
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

        // Lenient by contract, not by accident: the seeded body is a FortuneSheet array and an
        // unreadable body is an empty workbook. See `SheetFile.decode(from:)`.
        let file = SheetFile.decode(from: plaintext)
        logger.debug("loadWorkbook succeeded: id=\(fileID, privacy: .public) sheets=\(file.sheets.count)")
        return LoadedWorkbook(file: file, dek: dek, info: info,
                              needsInitialEncryption: needsInitialEncryption)
    }

    /// Fetches the file's sealed DEK, generating and storing one if the file has none yet.
    ///
    /// Returns whether the key was newly generated, which is the only thing that makes reading a
    /// failed decryption as plaintext safe.
    private func resolveDEK(fileID: String, token: String) async throws -> (dek: Bytes, isNew: Bool) {
        if let sealed = try await fetchSealedDEK(fileID: fileID, token: token) {
            return (try unsealDEK(sealed), false)
        }
        let dek: Bytes = Self.sodium.secretStream.xchacha20poly1305.key()
        try await storeFileKey(fileID: fileID, encryptedFileKey: try sealDEK(dek), token: token)
        logger.debug("resolveDEK: generated a new key for id=\(fileID, privacy: .public)")
        return (dek, true)
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
    @discardableResult
    func save(_ file: SheetFile, to fileID: String, dek: Bytes,
              expectedContentVersion: Int? = nil, title: String? = nil) async throws -> SaveResult {
        logger.debug("save: id=\(fileID, privacy: .public)")
        let token = try await authorizedToken()

        let xcss = Self.sodium.secretStream.xchacha20poly1305
        let plaintext = String(decoding: try file.encoded(), as: UTF8.self)
        let ciphertext = try encrypt(text: plaintext, dek: dek, xcss: xcss)

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
            return SaveResult(updatedAt: updated.updatedAt, sizeBytes: updated.sizeBytes,
                              contentVersion: updated.contentVersion)
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

    /// Encrypts `text` as `[24-byte header][ciphertext]` using an XChaCha20-Poly1305 secretstream.
    func encrypt(text: String, dek: Bytes, xcss: SecretStream.XChaCha20Poly1305) throws -> Data {
        guard let stream = xcss.initPush(secretKey: dek) else { throw SheetContentError.encryptionFailed }
        let header = stream.header()
        guard let cipher = stream.push(message: Array(text.utf8), tag: .FINAL) else {
            throw SheetContentError.encryptionFailed
        }
        return Data(header + cipher)
    }

    /// Reverses ``encrypt(text:dek:xcss:)``.
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

    /// Seals `dek` to the caller's stored Curve25519 public key (`crypto_box_seal`).
    func sealDEK(_ dek: Bytes) throws -> String {
        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString) else {
            throw SheetContentError.noEncryptionKey
        }
        guard let sealed = Self.sodium.box.seal(message: dek, recipientPublicKey: Array(pubKeyData)),
              let b64 = Self.sodium.utils.bin2base64(sealed, variant: .URLSAFE_NO_PADDING) else {
            throw SheetContentError.encryptionFailed
        }
        return b64
    }

    /// Reverses ``sealDEK(_:)`` using the caller's stored private key (`crypto_box_seal_open`).
    func unsealDEK(_ sealedBase64: String) throws -> Bytes {
        guard let pubKeyString = KeychainService.load(forKey: KeyImportService.publicKeyKeychainKey),
              let pubKeyData = Data(base64URLEncoded: pubKeyString),
              let privKeyString = KeychainService.load(forKey: KeyImportService.privateKeyKeychainKey),
              let privKeyData = Data(base64URLEncoded: privKeyString) else {
            logger.error("unsealDEK: no stored key pair, or the stored key is not valid Base64URL")
            throw SheetContentError.noEncryptionKey
        }
        guard let sealedBytes = Self.sodium.utils.base642bin(sealedBase64, variant: .URLSAFE_NO_PADDING) else {
            logger.error("unsealDEK: sealed key is not valid Base64URL")
            throw SheetContentError.decryptionFailed
        }
        guard let dek: Bytes = Self.sodium.box.open(
            anonymousCipherText: sealedBytes,
            recipientPublicKey: Array(pubKeyData),
            recipientSecretKey: Array(privKeyData)
        ) else {
            logger.error("unsealDEK: seal was not made to this device's public key")
            throw SheetContentError.decryptionFailed
        }
        return dek
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
            return try await session.data(for: request)
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
    private func fetchSealedDEK(fileID: String, token: String) async throws -> String? {
        let request = try makeRequest(method: "GET", path: "/api/v1/drive/files/\(fileID)/key", token: token)
        let (data, response) = try await self.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try Self.checkStatus(response)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(APIKeyResponse.self, from: data).encryptedFileKey
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

    private func storeFileKey(fileID: String, encryptedFileKey: String, token: String) async throws {
        var request = try makeRequest(method: "PUT",
                                      path: "/api/v1/drive/files/\(fileID)/key",
                                      token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["encryptedFileKey": encryptedFileKey])
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
