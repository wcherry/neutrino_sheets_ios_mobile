import Foundation
import CryptoKit
import XCTest
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
@testable import NeutrinoSheets

// MARK: - TestKeys

/// Installs a real X25519 key pair into the Keychain so the encryption paths can be exercised for
/// what they actually are.
///
/// The crypto is deliberately *not* mocked. `crypto_box_seal` / `secretstream` round trips are the
/// part of this app most expensive to get subtly wrong, and a fake that always "decrypts" would
/// assert nothing about them. libsodium's `crypto_box` uses X25519 keys, which is exactly what
/// `Curve25519.KeyAgreement` produces, so a CryptoKit-generated pair is interchangeable with the
/// one the web app exports.
enum TestKeys {

    /// Generates a pair and stores it under the same Keychain keys the app reads.
    @discardableResult
    static func install() -> KeyBundle {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let bundle = KeyBundle(
            publicKey: base64URL(priv.publicKey.rawRepresentation),
            privateKey: base64URL(priv.rawRepresentation),
            keyVersion: "1"
        )
        KeyImportService.storeKeys(bundle)
        return bundle
    }

    static func remove() {
        KeyImportService.removeKeys()
    }

    /// A valid key-file payload, in the format the web app exports.
    static func keyFileJSON() -> Data {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let dict = [
            "public_key": base64URL(priv.publicKey.rawRepresentation),
            "private_key": base64URL(priv.rawRepresentation),
            "key_version": "1",
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - TestTokens

/// Puts an access token in the Keychain so services believe they are signed in.
enum TestTokens {

    /// Decodes to `{"alg":"none","typ":"JWT"}.{"sub":"test-user-id"}.` — a real (if unsigned) JWT
    /// shape, not just an opaque string, because `SheetsDriveService.currentUserId()` reads the
    /// `sub` claim to address the drive root (`GET /api/v1/drive/folders/{id}` with `id` the
    /// caller's own user id). `userId` below is that same "test-user-id" so a test that seeds a
    /// token can assert against it.
    static let userId = "test-user-id"
    static let defaultAccessToken =
        "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ0ZXN0LXVzZXItaWQifQ."

    static func install(accessToken: String = TestTokens.defaultAccessToken) {
        KeychainService.save(accessToken, forKey: AuthService.accessTokenKey)
        // Far-future expiry so `refreshTokenIfNeeded` short-circuits and no test accidentally
        // depends on a refresh round trip it did not stub.
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        KeychainService.save(expiry, forKey: AuthService.tokenExpiryKey)
    }

    static func remove() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        KeychainService.delete(forKey: AuthService.refreshTokenKey)
        KeychainService.delete(forKey: AuthService.tokenExpiryKey)
    }
}

// MARK: - TestServer

/// Points the app at a fixed host so assertions on request URLs are stable.
enum TestServer {
    static let host = "https://test.neutrino.local"

    static func use() {
        UserDefaults.standard.set(host, forKey: AuthService.serverHostKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: AuthService.serverHostKey)
    }
}

// MARK: - MemoryPasteboard

/// A pasteboard that lives only for the test.
///
/// `UIPasteboard.general` is shared with every other app on the machine, so a suite that used it
/// would clear whatever the person running the tests had copied — and would read back whatever they
/// copied next. The editor takes its pasteboard as a dependency for exactly this reason.
final class MemoryPasteboard: PasteboardWriting {

    private(set) var payload: Data?
    private(set) var text: String?
    /// How many times a copy has been written, so a test can assert that one happened at all.
    private(set) var writeCount = 0

    func write(payload: Data?, text: String) {
        self.payload = payload
        self.text = text
        writeCount += 1
    }

    func readPayload() -> Data? { payload }
    func readText() -> String? { text }
    var hasContent: Bool { payload != nil || !(text ?? "").isEmpty }

    /// Drops the rich payload but keeps the text, standing in for a block copied in another app.
    func forgetRichPayload() { payload = nil }
}

// MARK: - Temp directories

extension XCTestCase {

    /// A unique empty directory, removed when the test finishes.
    func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeutrinoSheetsTests-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            XCTFail("Could not create temp directory: \(error)", file: file, line: line)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

// MARK: - Fixtures

enum Fixture {

    /// A spreadsheet item with sensible defaults, so a test only states what it cares about.
    static func sheet(id: String = "sheet-1",
                      name: String = "Budget",
                      parentID: String? = nil,
                      size: Int64? = 128,
                      modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                      isTrashed: Bool = false,
                      isStarred: Bool = false,
                      isShared: Bool = false,
                      mimeType: String = SheetItem.sheetMIME,
                      contentVersion: Int? = nil) -> SheetItem {
        SheetItem(id: id, name: name, type: .file, parentID: parentID, size: size,
                  modifiedAt: modifiedAt, isTrashed: isTrashed, mimeType: mimeType,
                  isStarred: isStarred, contentVersion: contentVersion, isShared: isShared)
    }

    static func folder(id: String = "folder-1",
                       name: String = "Projects",
                       parentID: String? = nil,
                       isStarred: Bool = false) -> SheetItem {
        SheetItem(id: id, name: name, type: .folder, parentID: parentID, size: nil,
                  modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), isTrashed: false,
                  mimeType: nil, isStarred: isStarred)
    }

    /// Drive's zone-less timestamp shape, as the file endpoints emit it.
    static func driveTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    /// A `GET /api/v1/drive` style listing body.
    static func listing(files: [String] = [], folders: [String] = []) -> Data {
        Data("""
        {"files":[\(files.joined(separator: ","))],"folders":[\(folders.joined(separator: ","))]}
        """.utf8)
    }

    static func fileJSON(id: String = "sheet-1",
                         name: String = "Budget",
                         folderId: String? = nil,
                         sizeBytes: Int = 128,
                         mimeType: String = SheetItem.sheetMIME,
                         updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                         isStarred: Bool = false,
                         contentVersion: Int? = nil) -> String {
        let folder = folderId.map { "\"\($0)\"" } ?? "null"
        let version = contentVersion.map { ",\"contentVersion\":\($0)" } ?? ""
        return """
        {"id":"\(id)","name":"\(name)","folderId":\(folder),"sizeBytes":\(sizeBytes),
         "mimeType":"\(mimeType)","updatedAt":"\(driveTimestamp(updatedAt))","isStarred":\(isStarred)\(version)}
        """
    }

    static func folderJSON(id: String = "folder-1",
                           name: String = "Projects",
                           parentId: String? = nil,
                           updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                           isStarred: Bool = false) -> String {
        let parent = parentId.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","name":"\(name)","parentId":\(parent),
         "updatedAt":"\(driveTimestamp(updatedAt))","isStarred":\(isStarred)}
        """
    }
}
