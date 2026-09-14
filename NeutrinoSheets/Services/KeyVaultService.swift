import Foundation
import os
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - Wire types
//
// The vault endpoints are camelCase on the wire. Decode them with a plain
// JSONDecoder — the app's shared snake-case-converting decoder would rewrite
// `memoryKiB` inside the params blob and break derivation.

struct VaultUnlockMethod: Codable, Equatable {
    let id: String
    /// "password" | "passkey" | "recovery"
    let method: String
    let label: String
    /// base64url( nonce || ciphertext of the master key ).
    let encryptedMasterKey: String
    /// JSON string: `Argon2Params` for password/recovery, PRF params for passkey.
    let params: String
    let createdAt: String?
    let lastUsedAt: String?
}

struct VaultResponse: Codable, Equatable {
    /// base64url( nonce || ciphertext of the Curve25519 secret key ).
    let encryptedIdentity: String
    let publicKey: String
    let version: Int
    let unlocks: [VaultUnlockMethod]
}

// MARK: - Errors

enum KeyVaultError: LocalizedError {
    case notAuthenticated
    case noVault
    case methodNotEnrolled(String)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You are signed out. Sign in and try again."
        case .noVault:
            return "No encryption key has been set up for this account yet. Open Neutrino on the web to set one up."
        case .methodNotEnrolled(let method):
            return method == "recovery"
                ? "No recovery code is enrolled for this account."
                : "No encryption password is enrolled for this account."
        case .serverError(let code):
            return "The server returned an error (\(code))."
        case .decodingError:
            return "The server sent a key vault this version of the app does not understand."
        }
    }
}

// MARK: - VaultStatus

/// What this device can currently do with the account's encryption key.
///
/// `locked` is the one that matters at sign-in: the account has published an identity and this
/// device does not hold it, so every spreadsheet would fail to open with "No encryption key found"
/// (see `SheetContentError.noEncryptionKey`) at the moment the user tried to read one. Knowing it
/// straight after sign-in is what lets the app ask for the encryption password then instead.
enum VaultStatus: Equatable {
    /// Not asked yet — the launch state, before the first `refresh()`.
    case unknown
    /// The identity key is on this device.
    case unlocked
    /// The account has a vault and this device does not hold its key.
    case locked
    /// The account has never created a vault. Only a key file or a recovery kit can help.
    case noVault
    /// The vault could not be fetched: offline, or the server said something unexpected.
    case unreachable

    var isUnlocked: Bool { self == .unlocked }
}

// MARK: - KeyVaultService
//
// Fetches the wrapped identity key and opens it with a password or recovery
// code, then hands the result to `KeyImportService` so the rest of the app
// keeps reading keys from the Keychain exactly as before.
//
// This is what replaces pasting a key bundle in by hand: the same secret the
// user set on the web unlocks the same identity here.
//
// Not implemented on this platform: passkey (PRF) unlock. The blob is stored
// and listed, and `unlock(password:)` skips it, so a passkey-only vault
// reports that no password is enrolled rather than failing obscurely.

@MainActor
final class KeyVaultService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var status: VaultStatus = .unknown

    /// The account's vault, once fetched. Held so the unlock screen knows which methods are
    /// enrolled and Settings can show the state without a second round trip.
    @Published private(set) var vault: VaultResponse?

    /// True when this device holds a key that is *not* this account's — what happens after signing
    /// out and into a different Neutrino account without removing the old key. Worth saying out
    /// loud, because the symptom otherwise is every spreadsheet failing to decrypt.
    @Published private(set) var keyBelongsToAnotherAccount = false

    weak var authService: AuthService?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoSheets",
                                category: "KeyVaultService")

    private static let decoder = JSONDecoder()

    private let session: URLSession

    private var baseURL: String {
        UserDefaults.standard.string(forKey: AuthService.serverHostKey) ?? AuthService.defaultHost
    }

    init(authService: AuthService? = nil, session: URLSession = .shared) {
        self.authService = authService
        self.session = session
    }

    // MARK: - Status

    /// Fetches the vault and works out where this device stands.
    ///
    /// Called at launch and after sign-in. Cheap enough to run every time — one GET — and it is the
    /// only thing that can notice a key left behind by a different account.
    func refresh() async {
        do {
            let fetched = try await fetchVault()
            vault = fetched
            guard let fetched else {
                // No vault on the server. A key imported by hand or restored from a recovery kit is
                // still a perfectly good key, so the presence of one still counts as unlocked.
                keyBelongsToAnotherAccount = false
                status = KeyImportService.hasStoredKeys() ? .unlocked : .noVault
                return
            }
            let stored = KeyImportService.storedKeys()
            let matches = stored.map { Self.samePublicKey($0.publicKey, fetched.publicKey) } ?? false
            keyBelongsToAnotherAccount = stored != nil && !matches
            status = matches ? .unlocked : .locked
            logger.debug("vault refreshed: \(String(describing: self.status), privacy: .public)")
        } catch is CancellationError {
            // Not an answer about the vault — whatever asked went away. Leaving `status` alone
            // matters: reporting `.unreachable` would put an offline warning on a screen that is
            // merely being dismissed.
            logger.debug("vault refresh cancelled")
        } catch {
            // Offline or a 5xx. Fall back to what the Keychain says rather than prompting for a
            // password the server could not have verified anyway — an unreachable server is not
            // evidence that this device has the wrong key.
            logger.error("vault refresh failed: \(error.localizedDescription, privacy: .public)")
            keyBelongsToAnotherAccount = false
            status = KeyImportService.hasStoredKeys() ? .unlocked : .unreachable
        }
    }

    /// Re-reads the Keychain without touching the network. Called after a key file is imported, a
    /// recovery kit is restored, or a first-run key is minted.
    func refreshFromKeychain() {
        guard KeyImportService.hasStoredKeys() else {
            keyBelongsToAnotherAccount = false
            status = vault == nil ? .noVault : .locked
            return
        }
        if let vault, let stored = KeyImportService.storedKeys() {
            let matches = Self.samePublicKey(stored.publicKey, vault.publicKey)
            keyBelongsToAnotherAccount = !matches
            status = matches ? .unlocked : .locked
            return
        }
        keyBelongsToAnotherAccount = false
        status = .unlocked
    }

    /// Forgets everything this service learned about the account. Called on sign-out so the next
    /// account to sign in here is asked about its own vault rather than judged against the last
    /// one's.
    func reset() {
        vault = nil
        keyBelongsToAnotherAccount = false
        status = .unknown
    }

    /// Which unlock methods this build can actually offer, in the order the unlock screen shows
    /// them. Passkey (PRF) unlock is not implemented here, so it is filtered out rather than
    /// offered and then failed.
    var availableMethods: [VaultUnlockMethod] {
        (vault?.unlocks ?? []).filter { $0.method != "passkey" }
    }

    // MARK: - Fetch

    /// The caller's vault, or nil when they have never set one up.
    func fetchVault() async throws -> VaultResponse? {
        let token = try await authorizedToken()
        guard let url = URL(string: baseURL + "/api/v1/auth/keyvault") else {
            throw KeyVaultError.serverError(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KeyVaultError.serverError(statusCode: 0)
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw KeyVaultError.serverError(statusCode: http.statusCode)
        }
        do {
            return try Self.decoder.decode(VaultResponse.self, from: data)
        } catch {
            logger.error("fetchVault: decode failed: \(error.localizedDescription, privacy: .public)")
            throw KeyVaultError.decodingError(underlying: error)
        }
    }

    // MARK: - Unlock

    /// Unlock with the encryption password and store the identity in the Keychain.
    @discardableResult
    func unlock(password: String) async throws -> KeyBundle {
        try await unlock(secret: password, method: "password")
    }

    /// Unlock with the recovery code shown when the vault was created.
    @discardableResult
    func unlock(recoveryCode: String) async throws -> KeyBundle {
        try await unlock(secret: KeyVaultCrypto.normalizeRecoveryCode(recoveryCode),
                         method: "recovery")
    }

    private func unlock(secret: String, method: String) async throws -> KeyBundle {
        let vault = try await requireVault()
        guard let unlockMethod = vault.unlocks.first(where: { $0.method == method }) else {
            throw KeyVaultError.methodNotEnrolled(method)
        }

        let params = try decodeArgon2Params(unlockMethod.params)
        // Argon2id is deliberately slow — around a second on an older phone — so the stretching
        // happens off the main actor, where it cannot freeze the unlock screen's own spinner.
        let encryptedMasterKey = unlockMethod.encryptedMasterKey
        let masterKey = try await Task.detached(priority: .userInitiated) {
            try KeyVaultCrypto.unwrapMasterKey(encryptedMasterKey: encryptedMasterKey,
                                               secret: secret, params: params)
        }.value
        let identity = try KeyVaultCrypto.openVault(
            encryptedIdentity: vault.encryptedIdentity,
            publicKeyB64URL: vault.publicKey,
            masterKey: masterKey
        )

        // Store base64url, matching what the web client writes and what the
        // existing import path already accepts.
        let bundle = KeyBundle(
            publicKey: KeyVaultCrypto.encodeBase64URL(identity.publicKey),
            privateKey: KeyVaultCrypto.encodeBase64URL(identity.secretKey),
            keyVersion: String(vault.version)
        )
        KeyImportService.storeKeys(bundle)
        keyBelongsToAnotherAccount = false
        status = .unlocked
        logger.info("unlock: vault opened via \(method, privacy: .public)")

        // The vault holds one identity, the active one. Anything sealed to a version this account
        // has rotated away from needs the key file, and this is the moment the key that opens it
        // arrives. A failure is not fatal: the next launch retries the pull.
        try? await KeyFileService.shared.restoreArchivedKeys(authService: authService)

        // Bookkeeping only — a failure here must not fail the unlock.
        await markUsed(unlockMethod.id)
        return bundle
    }

    /// The cached vault, fetching it first if `refresh()` has not run — an unlock screen opened
    /// straight from a banner may be the first thing that needs it.
    private func requireVault() async throws -> VaultResponse {
        if let vault { return vault }
        guard let fetched = try await fetchVault() else { throw KeyVaultError.noVault }
        vault = fetched
        return fetched
    }

    private func decodeArgon2Params(_ json: String) throws -> Argon2Params {
        guard let data = json.data(using: .utf8) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        do {
            return try Self.decoder.decode(Argon2Params.self, from: data)
        } catch {
            throw KeyVaultError.decodingError(underlying: error)
        }
    }

    // MARK: - Bookkeeping

    private func markUsed(_ unlockID: String) async {
        guard let token = try? await authorizedToken(),
              let url = URL(string: baseURL + "/api/v1/auth/keyvault/unlocks/\(unlockID)/used")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    // MARK: - Auth

    private func authorizedToken() async throws -> String {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw KeyVaultError.notAuthenticated
        }
        return token
    }

    // MARK: - Helpers

    /// Compares two public keys across encodings: the vault serves base64url, while a key file
    /// exported from the web app uses standard base64, and the two spellings of the same key must
    /// not read as different accounts.
    private static func samePublicKey(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = KeyVaultCrypto.decodeBase64URL(lhs),
              let right = KeyVaultCrypto.decodeBase64URL(rhs) else { return false }
        return left == right
    }
}
