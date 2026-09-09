import Foundation
import NeutrinoOOXML

// MARK: - XlsxCodec

/// The one door in and out of the `.xlsx` a Neutrino spreadsheet is stored as.
///
/// A native spreadsheet is a real Excel workbook (issue #127): the mime type is ``mimeType``, the
/// extension rides on the Drive file's *name* so a download lands on disk as something the operating
/// system can open, and every other office suite opens one directly.
///
/// Callers speak the stored `{"sheets":[…]}` JSON envelope the editors hold. That boundary is
/// deliberate and is what makes the round trip lossless without the codec knowing what a chart is:
/// the app decodes the same JSON it always did, so the parts it models stay typed and the parts it
/// only carries — charts, the conditional-format kinds OOXML cannot express, anything a later web
/// release adds — ride through its existing opaque-field mechanism untouched.
///
/// ## Two generations of stored body
///
/// A spreadsheet saved before the web's OOXML writer landed is an `.xlsx` carrying a
/// `neutrino/model.json` part: the OOXML beside it was a lossy projection, so the model won on
/// open. Nothing writes that part any more, and neither does this — but ``decode(_:)`` still reads
/// one, digest-guarded, exactly as the web does. Ignoring it would open such a workbook lossily on
/// the phone while it opened correctly on the web, which is the two clients disagreeing about the
/// same file.
enum XlsxCodec {

    // MARK: - Identity

    /// What Drive stores a Neutrino spreadsheet as.
static let mimeType =
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

static let fileExtension = "xlsx"

    /// The part a pre-OOXML save left the editor's own model in. Read, never written.
    static let legacyModelPart = "neutrino/model.json"

    /// The `app` a legacy model envelope must name to be this app's.
    private static let legacyModelApp = "sheets"

    // MARK: - Reading

    /// Reads `.xlsx` bytes into the stored `{"sheets":[…]}` envelope.
    ///
    /// A package carrying a trustworthy legacy model part yields that model verbatim; everything
    /// else is read from the worksheet parts.
static func decode(_ data: Data) throws -> OOXMLValue {
        if let model = legacyModel(in: data) { return model }
        return try XlsxReader.read(data)
    }

    /// The same, as the JSON bytes the caller stores.
static func decodeToJSON(_ data: Data) throws -> Data {
        try decode(data).serialized()
    }

    /// Whether these bytes are a workbook at all — the cheap check before reading.
static func isWorkbook(_ data: Data) -> Bool { XlsxReader.looksLikeWorkbook(data) }

    // MARK: - Writing

    /// Renders the stored envelope as `.xlsx` bytes.
    ///
    /// - Parameter keeping: the package this one replaces, whose parts nothing here understands —
    ///   pivot tables, images, charts another tool wrote — are carried into the result. Dropping
    ///   them on every save would make Neutrino the tool that quietly deletes your pivot table.
static func encode(_ file: OOXMLValue, keeping previous: Data? = nil) throws -> Data {
        try XlsxWriter.write(file, keep: previous)
    }

    /// The same, starting from the stored JSON bytes.
    ///
    /// Bytes that are not a workbook envelope at all yield an empty workbook rather than throwing:
    /// the caller is part-way through saving, and a body it cannot encode is a bug here rather than
    /// something the user can act on.
static func encodeJSON(_ json: Data, keeping previous: Data? = nil) throws -> Data {
        try encode(OOXMLValue.parse(json) ?? emptyWorkbookModel, keeping: previous)
    }

    /// A valid, empty `.xlsx` — what a newly created spreadsheet holds until its first save.
    ///
    /// A new file is created with no body at all (`native_types.rs` seeds the OOXML types with an
    /// empty string, because a zip is not something the server has any business building), so this
    /// is what the app writes in its place the moment it has one.
static func emptyWorkbook() throws -> Data {
        try encode(emptyWorkbookModel)
    }

    /// The model an empty workbook holds: one tab, named the way the web names it.
static var emptyWorkbookModel: OOXMLValue {
        .object(["sheets": .array([.object(["name": .string("Sheet 1"),
                                            "cells": .object([:])])])])
    }

    // MARK: - Names

    /// `name` with `.xlsx` on the end, added only if it is not already there.
    ///
    /// The extension is part of the *file* name because a download has to land on disk as
    /// `Budget.xlsx` to open on a double-click. Renaming "Budget" twice must not produce
    /// `Budget.xlsx.xlsx`.
static func withExtension(_ name: String) -> String {
        hasExtension(name) ? name : "\(name).\(fileExtension)"
    }

    /// `name` without a trailing `.xlsx` — the title to show for a file.
    ///
    /// A file genuinely called "Q3.report" keeps its name, and so does a legacy `.xls`: only the
    /// modern extension is stripped.
static func strippingExtension(_ name: String) -> String {
        hasExtension(name) ? String(name.dropLast(fileExtension.count + 1)) : name
    }

    private static func hasExtension(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".\(fileExtension)")
    }

    // MARK: - The legacy model part

    /// The editor model stored in `data`, or nil when there is none to trust — a package written by
    /// another tool, one whose model belongs to a different editor, or one whose parts have changed
    /// since the model was written.
    ///
    /// Every nil means the same thing to the caller: read the OOXML instead.
    static func legacyModel(in data: Data) -> OOXMLValue? {
        guard ZipArchive.looksLikeArchive(data), let zip = try? ZipArchive(data: data),
              let raw = zip.text(for: legacyModelPart),
              let envelope = OOXMLValue.parse(raw),
              envelope["version"]?.intValue == 1,
              envelope["app"]?.stringValue == legacyModelApp,
              let model = envelope["model"]?.stringValue,
              envelope["digest"]?.stringValue == digest(of: zip)
        else { return nil }
        // The envelope holds the model as a *string* of JSON, which is the shape the editors stored.
        return OOXMLValue.parse(model)
    }

    /// FNV-1a over every part except the model, name included, in a fixed order.
    ///
    /// Not a cryptographic hash and not meant to be: the question it answers is "did something
    /// rewrite this package behind our back", where the alternative to a cheap answer is no answer
    /// at all. Names are hashed alongside contents so an added or removed part registers even when
    /// nothing else moved. This must agree byte for byte with `digestParts` in
    /// `web/apps/web/src/lib/ooxmlContainer.ts` or every legacy model would be discarded.
    private static func digest(of zip: ZipArchive) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x100_0000_01b3
        func mix(_ byte: UInt8) {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        for name in zip.names.sorted() where name != legacyModelPart {
            for byte in Array(name.utf8) { mix(byte) }
            for byte in zip.data(for: name) ?? Data() { mix(byte) }
        }
        return String(format: "%016lx", hash)
    }
}
