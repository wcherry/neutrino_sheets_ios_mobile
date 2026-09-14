import XCTest
import CryptoKit
import NeutrinoAuth
import NeutrinoCrypto
@testable import NeutrinoSheets

// MARK: - KeyVaultServiceTests
//
// `refresh()` is what the app asks at sign-in, and its answer decides whether the user is prompted
// for their encryption password or left alone. Both mistakes are bad in a visible way: a spurious
// `.locked` asks somebody who is perfectly set up to type a password for no reason, and a missed
// one lets them sign in, browse, and only discover the problem when the first spreadsheet refuses to
// open. So every branch is pinned here — including the two that must *not* prompt, an unreachable
// server and an account that has no vault at all.
//
// The keys are real X25519 pairs rather than fixtures: the comparison this class exists to make is
// "is the key on this device the key this account published", and a string fixture would assert
// nothing about the encoding mismatch that makes it interesting (see the base64 test at the end).

@MainActor
final class KeyVaultServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestServer.use()
        TestTokens.install()
        MockURLProtocol.reset()
        KeyImportService.removeKeys()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        KeyImportService.removeKeys()
        TestTokens.remove()
        TestServer.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeService() -> KeyVaultService {
        KeyVaultService(session: MockURLProtocol.makeSession())
    }

    /// A vault response as the server serves it: camelCase, base64url, one enrolled password.
    private func vaultJSON(publicKey: String, version: Int = 1) -> String {
        """
        {
          "encryptedIdentity": "\(String(repeating: "A", count: 43))",
          "publicKey": "\(publicKey)",
          "version": \(version),
          "unlocks": [
            {
              "id": "unlock-1",
              "method": "password",
              "label": "Encryption password",
              "encryptedMasterKey": "\(String(repeating: "B", count: 43))",
              "params": "{\\"salt\\":\\"c2FsdA\\",\\"timeCost\\":3,\\"memoryKiB\\":65536,\\"parallelism\\":1}",
              "createdAt": null,
              "lastUsedAt": null
            }
          ]
        }
        """
    }

    /// A public key that is *not* the one in the Keychain — a second account's identity.
    private func otherPublicKey() -> String {
        TestKeys.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
    }

    // MARK: - The signed-in device holds the right key

    func testRefreshReportsUnlockedWhenStoredKeyMatchesVault() async {
        let bundle = TestKeys.install()
        MockURLProtocol.respond(json: vaultJSON(publicKey: bundle.publicKey))

        let sut = makeService()
        await sut.refresh()

        XCTAssertEqual(sut.status, .unlocked)
        XCTAssertFalse(sut.keyBelongsToAnotherAccount)
    }

    // MARK: - The signed-in device holds no key

    func testRefreshReportsLockedWhenDeviceHasNoKey() async {
        MockURLProtocol.respond(json: vaultJSON(publicKey: otherPublicKey()))

        let sut = makeService()
        await sut.refresh()

        // The case the whole feature exists for: a device that has just signed in to an account
        // whose spreadsheets it cannot read.
        XCTAssertEqual(sut.status, .locked)
        XCTAssertFalse(sut.keyBelongsToAnotherAccount,
                       "No key at all is not the same as somebody else's key")
    }

    // MARK: - The device holds another account's key

    func testRefreshFlagsKeyLeftBehindByAnotherAccount() async {
        TestKeys.install()
        MockURLProtocol.respond(json: vaultJSON(publicKey: otherPublicKey()))

        let sut = makeService()
        await sut.refresh()

        // Signed out of one account and into another without removing the key. Without the flag
        // the symptom is every spreadsheet failing to decrypt with no explanation.
        XCTAssertEqual(sut.status, .locked)
        XCTAssertTrue(sut.keyBelongsToAnotherAccount)
    }

    // MARK: - No vault on the server

    func testRefreshReportsNoVaultWhenAccountHasNoneAndDeviceHasNoKey() async {
        MockURLProtocol.respond(json: "", statusCode: 404)

        let sut = makeService()
        await sut.refresh()

        // Nothing to unlock *with*: prompting for an encryption password that was never set would
        // send the user looking for something that does not exist.
        XCTAssertEqual(sut.status, .noVault)
        XCTAssertNil(sut.vault)
    }

    func testRefreshReportsUnlockedWhenAccountHasNoVaultButDeviceHasAKey() async {
        TestKeys.install()
        MockURLProtocol.respond(json: "", statusCode: 404)

        let sut = makeService()
        await sut.refresh()

        // A key imported by hand or restored from a recovery kit reads spreadsheets perfectly well
        // whether or not the account ever published a vault.
        XCTAssertEqual(sut.status, .unlocked)
    }

    // MARK: - The server did not answer

    func testRefreshReportsUnreachableRatherThanLockedWhenServerFails() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let sut = makeService()
        await sut.refresh()

        // Offline is not evidence that this device has the wrong key, and `.unreachable` is not a
        // state `RootView` prompts on — asking for a password the server could not have verified
        // would be a dead end.
        XCTAssertEqual(sut.status, .unreachable)
        XCTAssertNotEqual(sut.status, .locked)
    }

    func testRefreshKeepsUnlockedWhenServerFailsButDeviceHasAKey() async {
        TestKeys.install()
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }

        let sut = makeService()
        await sut.refresh()

        XCTAssertEqual(sut.status, .unlocked)
        XCTAssertFalse(sut.keyBelongsToAnotherAccount)
    }

    // MARK: - Keychain-only updates

    func testRefreshFromKeychainGoesLockedAfterKeysAreRemoved() async {
        let bundle = TestKeys.install()
        MockURLProtocol.respond(json: vaultJSON(publicKey: bundle.publicKey))

        let sut = makeService()
        await sut.refresh()
        XCTAssertEqual(sut.status, .unlocked)

        // Settings › Remove Keys, with the vault already known — no second round trip needed to
        // work out that this device can no longer read anything.
        KeyImportService.removeKeys()
        sut.refreshFromKeychain()

        XCTAssertEqual(sut.status, .locked)
    }

    func testRefreshFromKeychainGoesUnlockedAfterAKeyArrives() async {
        MockURLProtocol.respond(json: "", statusCode: 404)

        let sut = makeService()
        await sut.refresh()
        XCTAssertEqual(sut.status, .noVault)

        // A key file imported, or a first-run key minted.
        TestKeys.install()
        sut.refreshFromKeychain()

        XCTAssertEqual(sut.status, .unlocked)
    }

    // MARK: - Sign-out

    func testResetForgetsTheAccountItLearnedAbout() async {
        let bundle = TestKeys.install()
        MockURLProtocol.respond(json: vaultJSON(publicKey: bundle.publicKey))

        let sut = makeService()
        await sut.refresh()
        XCTAssertNotNil(sut.vault)

        sut.reset()

        // The next account to sign in on this device must be asked about its own vault, not
        // measured against the one that just left.
        XCTAssertEqual(sut.status, .unknown)
        XCTAssertNil(sut.vault)
        XCTAssertFalse(sut.keyBelongsToAnotherAccount)
    }

    // MARK: - Encoding

    func testRefreshTreatsBase64AndBase64URLSpellingsAsTheSameKey() async {
        // The vault serves base64url; a key file exported from the web app uses standard base64.
        // Comparing the strings would call one account two, lock a device that is perfectly set up,
        // and — worse — tell the user their key belongs to somebody else.
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let raw = priv.publicKey.rawRepresentation
        KeyImportService.storeKeys(KeyBundle(
            publicKey: raw.base64EncodedString(),
            privateKey: priv.rawRepresentation.base64EncodedString(),
            keyVersion: "1"
        ))
        MockURLProtocol.respond(json: vaultJSON(publicKey: TestKeys.base64URL(raw)))

        let sut = makeService()
        await sut.refresh()

        XCTAssertEqual(sut.status, .unlocked)
        XCTAssertFalse(sut.keyBelongsToAnotherAccount)
    }

    // MARK: - Request shape

    func testRefreshSendsAnAuthorizedGetToTheVaultEndpoint() async {
        MockURLProtocol.respond(json: vaultJSON(publicKey: otherPublicKey()))

        await makeService().refresh()

        let request = MockURLProtocol.request { $0.url?.path == "/api/v1/auth/keyvault" }
        XCTAssertNotNil(request, "refresh() must ask the vault endpoint")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(TestTokens.defaultAccessToken)")
    }
}
