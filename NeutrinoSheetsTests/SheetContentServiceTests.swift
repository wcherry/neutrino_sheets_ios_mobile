import XCTest
import Sodium
@testable import NeutrinoSheets

/// Epic 7 — content load and save, and the client-side checks the drive refactor moved off the
/// server. Risk 4 of the roadmap names three of these as "quiet API-contract bugs": each needs a
/// test, not a careful reading.
@MainActor
final class SheetContentServiceTests: XCTestCase {

    private var session: URLSession!
    private var service: SheetContentService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestKeys.install()
        TestTokens.install()
        session = MockURLProtocol.makeSession()
        service = SheetContentService(session: session)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestKeys.remove()
        TestTokens.remove()
        TestServer.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Seals a DEK to the installed test key pair, as `PUT /files/{id}/key` would have stored it.
    private func sealedKey(for dek: Bytes) throws -> String {
        try service.sealDEK(dek)
    }

    private func encrypted(_ text: String, with dek: Bytes) throws -> Data {
        try service.encrypt(text: text, dek: dek, xcss: Sodium().secretStream.xchacha20poly1305)
    }

    private func infoJSON(id: String = "sheet-1",
                          mimeType: String = SheetItem.sheetMIME,
                          yourRole: String = "owner",
                          contentVersion: Int = 4,
                          updatedAt: String = "2026-08-10T12:00:00") -> Data {
        Data("""
        {"id":"\(id)","name":"Budget","sizeBytes":128,"folderId":null,
         "mimeType":"\(mimeType)","updatedAt":"\(updatedAt)","yourRole":"\(yourRole)",
         "contentVersion":\(contentVersion)}
        """.utf8)
    }

    // MARK: - Create (consequence 1)

    /// "Create is one request, not two." The client supplies the id, the server seeds the body.
    func testCreateIsASinglePostWithAClientSuppliedId() async throws {
        MockURLProtocol.route([
            (suffix: "/drive/files", statusCode: 201, body: Data("""
             {"id":"new-1","name":"Budget","folderId":null,"sizeBytes":103,
              "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:00:00","contentVersion":1}
             """.utf8)),
            (suffix: "/key", statusCode: 200, body: Data(#"{"encrypted_file_key":"x"}"#.utf8)),
        ])

        let item = try await service.createSpreadsheet(name: "Budget", parentID: nil)

        XCTAssertEqual(item.id, "new-1")
        XCTAssertEqual(item.mimeType, SheetItem.sheetMIME)
        XCTAssertEqual(item.contentVersion, 1)

        // Exactly two requests: the create, and the key. Not the Docs app's `/upload` two-step.
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        let create = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertTrue(create.url?.path.hasSuffix("/drive/files") ?? false, create.url?.path ?? "")

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MockURLProtocol.bodies[0]) as? [String: Any]
        )
        // A client-supplied UUID, so the editor can open before the response lands.
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(body["id"] as? String)))
        XCTAssertEqual(body["mimeType"] as? String, SheetItem.sheetMIME)
        // `initialContent` is deliberately absent: the server seeds the default itself, and a
        // client-written body here would be stored as plaintext.
        XCTAssertNil(body["initialContent"])
    }

    // MARK: - Mime check (consequence 2)

    /// `/info` answers for any file type now, so "is this a spreadsheet?" is the client's job.
    /// Nothing server-side stops this app opening a raw `.xlsx` and drawing an empty grid.
    func testOpeningANonSpreadsheetIsRefused() async {
        MockURLProtocol.route([
            (suffix: "/info", statusCode: 200, body: infoJSON(mimeType: SheetItem.xlsxMIME)),
        ])

        do {
            _ = try await service.loadWorkbook(for: "sheet-1")
            XCTFail("expected a notASpreadsheet error")
        } catch let error as SheetContentError {
            guard case .notASpreadsheet(let mime) = error else {
                return XCTFail("expected notASpreadsheet, got \(error)")
            }
            XCTAssertEqual(mime, SheetItem.xlsxMIME)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFileInfoReportsWhetherAFileIsANativeSheet() async throws {
        MockURLProtocol.route([(suffix: "/info", statusCode: 200, body: infoJSON())])
        let info = try await service.fileInfo(for: "sheet-1")

        XCTAssertEqual(info?.isNativeSheet, true)
        XCTAssertEqual(info?.yourRole, .owner)
        XCTAssertEqual(info?.contentVersion, 4)
        XCTAssertEqual(info?.isLive, true)
    }

    func testFileInfoReturnsNilForUnreachableFiles() async throws {
        for status in [403, 404] {
            MockURLProtocol.route([(suffix: "/info", statusCode: status, body: Data())])
            let info = try await service.fileInfo(for: "sheet-1")
            XCTAssertNil(info, "status \(status) should read as 'not mine to read'")
        }
    }

    // MARK: - Naive timestamps (consequence 3)

    /// Drive serialises `2026-08-10T12:00:00` with no offset, and the value is UTC. Reading it as
    /// local time would shift every "Modified" time by the device's offset — a silent,
    /// plausible-looking bug, which is why it is asserted rather than assumed.
    func testOffsetLessTimestampsAreReadAsUTC() async throws {
        MockURLProtocol.route([
            (suffix: "/info", statusCode: 200, body: infoJSON(updatedAt: "2026-08-10T12:00:00")),
        ])

        let info = try await service.fileInfo(for: "sheet-1")

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 10; components.hour = 12
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(info?.updatedAt, utc.date(from: components))
    }

    func testDriveDateHandlesEveryShapeDriveEmits() {
        // Naive (file payloads), naive with microseconds, and RFC 3339 (version payloads).
        let naive = DriveDate.date(from: "2026-08-10T12:00:00")
        let micro = DriveDate.date(from: "2026-08-10T12:00:00.123456")
        let zoned = DriveDate.date(from: "2026-08-10T12:00:00Z")

        XCTAssertNotNil(naive)
        XCTAssertNotNil(micro)
        XCTAssertNotNil(zoned)
        // A zone-less timestamp means UTC, so it must equal the same instant spelled with a Z.
        XCTAssertEqual(naive, zoned)
        XCTAssertEqual(micro?.timeIntervalSince1970 ?? 0,
                       (zoned?.timeIntervalSince1970 ?? 0) + 0.123, accuracy: 0.001)
    }

    // MARK: - Load

    func testLoadsAndDecryptsAWorkbook() async throws {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        let workbook = #"{"sheets":[{"name":"Q3","cells":{"A1":{"id":"A1","value":"7"}}}]}"#

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let ok = { (data: Data) in
                (HTTPURLResponse(url: request.url!, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!, data)
            }
            if path.hasSuffix("/info") { return ok(self.infoJSON()) }
            if path.hasSuffix("/key") {
                return ok(Data("{\"encrypted_file_key\":\"\(try self.sealedKey(for: dek))\"}".utf8))
            }
            return ok(try self.encrypted(workbook, with: dek))
        }

        let loaded = try await service.loadWorkbook(for: "sheet-1")

        XCTAssertEqual(loaded.file.sheets.count, 1)
        XCTAssertEqual(loaded.file.sheets[0].name, "Q3")
        XCTAssertEqual(loaded.file.sheets[0].cells["A1"]?.value, "7")
        XCTAssertFalse(loaded.needsInitialEncryption)
        XCTAssertEqual(loaded.dek, dek)
    }

    /// A brand-new spreadsheet holds the server's *plaintext* seed, because the body is written
    /// before any client has a key for the file. Decryption failing is expected here, and the
    /// bytes are the FortuneSheet default.
    func testANewSpreadsheetsPlaintextSeedIsReadAndFlaggedForEncryption() async throws {
        let seeded = #"[{"index":"0","name":"Sheet1","celldata":[],"row":100,"column":26}]"#

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let status = path.hasSuffix("/key") && request.httpMethod == "GET" ? 404 : 200
            let body: Data
            if path.hasSuffix("/info") {
                body = self.infoJSON()
            } else if path.hasSuffix("/key") {
                body = Data(#"{"encrypted_file_key":"stored"}"#.utf8)
            } else {
                body = Data(seeded.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!, body)
        }

        let loaded = try await service.loadWorkbook(for: "sheet-1")

        XCTAssertTrue(loaded.needsInitialEncryption)
        XCTAssertEqual(loaded.file.sheets.count, 1)
        XCTAssertEqual(loaded.file.sheets[0].name, "Sheet1")

        // A key was generated and stored, since the file had none.
        XCTAssertTrue(MockURLProtocol.requests.contains {
            $0.httpMethod == "PUT" && ($0.url?.path.hasSuffix("/key") ?? false)
        })
    }

    /// The dangerous half of the same branch: an *existing* key that will not decrypt means the
    /// bytes are ciphertext this device cannot read. Treating them as plaintext would let the next
    /// save replace a file nobody can recover with an empty workbook.
    func testUndecryptableContentUnderAnExistingKeyIsAnError() async {
        let storedDEK = Sodium().secretStream.xchacha20poly1305.key()
        let otherDEK = Sodium().secretStream.xchacha20poly1305.key()

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let ok = { (data: Data) in
                (HTTPURLResponse(url: request.url!, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!, data)
            }
            if path.hasSuffix("/info") { return ok(self.infoJSON()) }
            if path.hasSuffix("/key") {
                return ok(Data("{\"encrypted_file_key\":\"\(try self.sealedKey(for: storedDEK))\"}".utf8))
            }
            // Encrypted under a *different* key than the one the server hands back.
            return ok(try self.encrypted("{}", with: otherDEK))
        }

        do {
            _ = try await service.loadWorkbook(for: "sheet-1")
            XCTFail("expected a decryption failure")
        } catch let error as SheetContentError {
            guard case .decryptionFailed = error else {
                return XCTFail("expected decryptionFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Save

    func testSaveSendsEncryptedMultipartWithTheVersionGuard() async throws {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: """
        {"id":"sheet-1","name":"Budget","folderId":null,"sizeBytes":42,
         "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:00:00","contentVersion":5}
        """)

        let file = SheetFile(sheets: [SheetData(name: "Q3")])
        let result = try await service.save(file, to: "sheet-1", dek: dek, expectedContentVersion: 4)

        XCTAssertEqual(result.contentVersion, 5)
        XCTAssertEqual(result.sizeBytes, 42)

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        // The guard is what lets the *server* reject a stale write, closing the check-then-write gap.
        XCTAssertEqual(request.url?.query, "expectedContentVersion=4")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?
            .hasPrefix("multipart/form-data") ?? false)

        // The part is named `file` and carries `sheet.json`, matching the web client.
        let body = String(decoding: MockURLProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="file""#), body.prefix(400).description)
        XCTAssertTrue(body.contains("sheet.json"))
        // And what it carries is ciphertext, not the workbook JSON.
        XCTAssertFalse(body.contains("\"sheets\""))
    }

    func testSaveCanCarryARenameInTheMetadataPart() async throws {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: """
        {"id":"sheet-1","name":"Renamed","folderId":null,"sizeBytes":42,
         "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:00:00","contentVersion":5}
        """)

        _ = try await service.save(SheetFile(), to: "sheet-1", dek: dek, title: "Renamed \"Q3\"")

        let body = String(decoding: MockURLProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="metadata""#), body)
        // Properly JSON-escaped, so a quote in the title cannot break the part.
        XCTAssertTrue(body.contains(#"{"title":"Renamed \"Q3\""}"#), body)
    }

    func testSaveOmitsTheGuardWhenThereIsNoKnownVersion() async throws {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: """
        {"id":"sheet-1","name":"Budget","folderId":null,"sizeBytes":42,
         "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:00:00","contentVersion":1}
        """)

        _ = try await service.save(SheetFile(), to: "sheet-1", dek: dek, expectedContentVersion: nil)

        XCTAssertNil(MockURLProtocol.requests.first?.url?.query)
    }

    // MARK: - Conflict

    func testA409WithTheConflictCodeBecomesAVersionConflict() async {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: """
        {"error":{"code":"CONTENT_VERSION_CONFLICT",
                  "message":"expected version 4 but found 7"}}
        """, statusCode: 409)

        do {
            _ = try await service.save(SheetFile(), to: "sheet-1", dek: dek,
                                       expectedContentVersion: 4)
            XCTFail("expected a conflict")
        } catch let error as SheetContentError {
            guard case .contentVersionConflict(let current) = error else {
                return XCTFail("expected contentVersionConflict, got \(error)")
            }
            // The server states the version it holds, which saves a round trip when resolving.
            XCTAssertEqual(current, 7)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Drive uses 409 for other faults too — a file whose content is missing from storage, for one.
    /// Reporting those as "your edit is stale" would tell the user to reload over a fault reloading
    /// cannot fix.
    func testAnUnrelated409IsNotReportedAsAConflict() async {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        MockURLProtocol.respond(json: #"{"error":{"code":"CONTENT_MISSING","message":"gone"}}"#,
                                statusCode: 409)

        do {
            _ = try await service.save(SheetFile(), to: "sheet-1", dek: dek,
                                       expectedContentVersion: 4)
            XCTFail("expected an error")
        } catch let error as SheetContentError {
            guard case .serverError(let code) = error else {
                return XCTFail("expected serverError, got \(error)")
            }
            XCTAssertEqual(code, 409)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Crypto round trip

    /// Not mocked, on purpose: the seal/unseal and secretstream round trips are the part of this
    /// app most expensive to get subtly wrong, and a fake that always "decrypts" asserts nothing.
    func testEncryptDecryptRoundTrip() throws {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        let workbook = #"{"sheets":[{"name":"Q3","cells":{}}]}"#

        let ciphertext = try encrypted(workbook, with: dek)
        XCTAssertNotEqual(ciphertext, Data(workbook.utf8))
        // The 24-byte secretstream header prefixes every ciphertext this app writes.
        XCTAssertGreaterThan(ciphertext.count, 24)

        let plaintext = try service.decrypt(data: ciphertext, dek: dek)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), workbook)
    }

    func testSealedDEKRoundTrip() throws {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        let sealed = try service.sealDEK(dek)
        XCTAssertEqual(try service.unsealDEK(sealed), dek)
    }

    func testDecryptRejectsATruncatedBody() {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        XCTAssertThrowsError(try service.decrypt(data: Data(repeating: 0, count: 8), dek: dek))
    }
}
