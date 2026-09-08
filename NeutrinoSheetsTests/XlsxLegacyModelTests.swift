import XCTest
import NeutrinoOOXML
@testable import NeutrinoSheets

/// The `neutrino/model.json` part a spreadsheet saved before the OOXML writer landed still carries.
///
/// Nothing writes it any more. It is read — digest-guarded — because the web still reads it, and a
/// client that ignored it would open such a workbook lossily while the web opened it correctly.
/// The counterpart of `web/apps/web/src/__tests__/ooxml/container.test.ts`.
final class XlsxLegacyModelTests: XCTestCase {

    /// A model whose contents the OOXML parts deliberately do *not* carry, so a test can tell which
    /// of the two was read.
    private let model = OOXMLValue.object(["sheets": .array([
        .object([
            "name": .string("From the model"),
            "cells": .object(["A1": .object([
                "id": .string("A1"), "raw": .string("model wins"), "value": .string("model wins"),
            ])]),
        ]),
    ])])

    /// A package whose worksheet says one thing and whose model part says another.
    private func packageCarryingModel(app: String = "sheets", version: Int = 1,
                                      tamper: Bool = false) throws -> Data {
        let ooxml = try XlsxCodec.encode(.object(["sheets": .array([
            .object([
                "name": .string("From the OOXML"),
                "cells": .object(["A1": .object([
                    "id": .string("A1"), "raw": .string("ooxml"), "value": .string("ooxml"),
                ])]),
            ]),
        ])]))

        var zip = try ZipArchive(data: ooxml)
        // The digest covers the package as it will be stored, so anything that changes a part has
        // to happen before it is computed.
        if tamper { zip.set("xl/worksheets/sheet1.xml", text: "<worksheet/>") }
        let digest = Self.digest(of: zip)
        zip.set(XlsxCodec.legacyModelPart, text: OOXMLValue.object([
            "version": .number(Double(version)),
            "app": .string(app),
            "digest": .string(digest),
            "model": .string(model.serializedString()),
        ]).serializedString())
        return try zip.serialized()
    }

    /// FNV-1a over every part except the model, name included, in sorted order — the same function
    /// `XlsxCodec` and `ooxmlContainer.ts` compute, restated here so the test does not simply agree
    /// with the implementation by calling it.
    private static func digest(of zip: ZipArchive) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for name in zip.names.sorted() where name != XlsxCodec.legacyModelPart {
            for byte in Array(name.utf8) { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            for byte in zip.data(for: name) ?? Data() {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return String(format: "%016lx", hash)
    }

    // MARK: - Tests

    func testATrustworthyModelPartWinsOverTheWorksheet() throws {
        let package = try packageCarryingModel()
        let result = try XlsxCodec.decode(package)
        XCTAssertEqual(result["sheets"]?[0]?["name"]?.stringValue, "From the model")
        XCTAssertEqual(result["sheets"]?[0]?["cells"]?["A1"]?["raw"]?.stringValue, "model wins")
    }

    /// Excel and LibreOffice discard parts they don't recognise, but a tool that *keeps* the model
    /// while rewriting the workbook would be worse: a stale model would quietly overwrite the
    /// outside edit. The digest is what closes that off.
    func testAModelWhoseDigestNoLongerMatchesIsIgnored() throws {
        var zip = try ZipArchive(data: try packageCarryingModel())
        // Edit the workbook the way another tool would, leaving the model behind.
        zip.set("xl/worksheets/sheet1.xml", text: try XCTUnwrap(
            ZipArchive(data: try XlsxCodec.encode(.object(["sheets": .array([
                .object(["name": .string("Edited elsewhere"),
                         "cells": .object(["A1": .object([
                             "id": .string("A1"), "raw": .string("outside edit"),
                             "value": .string("outside edit"),
                         ])])]),
            ])]))).text(for: "xl/worksheets/sheet1.xml")))

        let result = try XlsxCodec.decode(try zip.serialized())
        XCTAssertEqual(result["sheets"]?[0]?["cells"]?["A1"]?["raw"]?.stringValue, "outside edit")
    }

    func testAModelBelongingToAnotherEditorIsIgnored() throws {
        let package = try packageCarryingModel(app: "slides")
        XCTAssertNil(XlsxCodec.legacyModel(in: package))
        XCTAssertEqual(try XlsxCodec.decode(package)["sheets"]?[0]?["name"]?.stringValue,
                       "From the OOXML")
    }

    func testAModelOfAnUnknownVersionIsIgnored() throws {
        XCTAssertNil(XlsxCodec.legacyModel(in: try packageCarryingModel(version: 2)))
    }

    func testAPackageWithNoModelPartReadsItsOOXML() throws {
        let package = try XlsxCodec.encode(.object(["sheets": .array([
            .object(["name": .string("Plain"), "cells": .object([:])]),
        ])]))
        XCTAssertNil(XlsxCodec.legacyModel(in: package))
        XCTAssertEqual(try XlsxCodec.decode(package)["sheets"]?[0]?["name"]?.stringValue, "Plain")
    }

    /// Nothing writes the part any more, so a workbook saved by this client must not grow one back.
    func testSavingDoesNotWriteAModelPart() throws {
        let saved = try XlsxCodec.encode(try XlsxCodec.decode(try packageCarryingModel()))
        XCTAssertFalse(try ZipArchive(data: saved).contains(XlsxCodec.legacyModelPart))
    }

    /// Reading a legacy package and saving it is what migrates it: the model's contents become the
    /// worksheet's.
    func testReadingThenSavingMigratesTheModelIntoTheWorksheet() throws {
        let migrated = try XlsxCodec.encode(try XlsxCodec.decode(try packageCarryingModel()))
        let result = try XlsxCodec.decode(migrated)
        XCTAssertEqual(result["sheets"]?[0]?["name"]?.stringValue, "From the model")
        XCTAssertEqual(result["sheets"]?[0]?["cells"]?["A1"]?["raw"]?.stringValue, "model wins")
    }
}
