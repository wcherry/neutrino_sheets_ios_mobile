import Foundation

// MARK: - JSONValue

/// Any JSON value, decoded and re-encoded without being understood.
///
/// This exists for one reason: a phone will always understand less of the spreadsheet format than
/// the web app does. A workbook saved from Neutrino Sheets on the web can carry charts, conditional
/// formats, named CF variables and table regions that this app cannot yet render — and a decoder
/// that only knows the fields it renders would drop every one of them on the first mobile save.
/// The user would open the file on the web afterwards to find their charts gone, with nothing
/// having failed anywhere.
///
/// So `SheetData` decodes the fields it renders into typed properties and everything else into a
/// `[String: JSONValue]`, which is written back out verbatim. The app does not have to know what
/// `charts` means to keep it.
///
/// Key order is the one thing not preserved: `JSONEncoder` writes dictionaries in whatever order
/// it likes unless told otherwise, and `.sortedKeys` is used throughout so a round trip is at least
/// *stable* — the same input always produces the same output. That is what the round-trip fixtures
/// assert. The web app re-parses the JSON either way, so ordering carries no meaning.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Decoding

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unrecognised JSON value")
        }
    }

    // MARK: - Encoding

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let v):     try container.encode(v)
        case .number(let v):   try encode(number: v, into: &container)
        case .string(let v):   try container.encode(v)
        case .array(let v):    try container.encode(v)
        case .object(let v):   try container.encode(v)
        }
    }

    /// Writes a whole-valued `Double` as an integer.
    ///
    /// Without this, a chart's `{"width": 400}` comes back as `400.0` after a round trip — still
    /// valid JSON and still the same number, but a visible, needless diff in every file the phone
    /// touches, and one that would make the byte-stability fixtures fail for a reason that has
    /// nothing to do with data loss.
    private func encode(number: Double, into container: inout SingleValueEncodingContainer) throws {
        if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
            try container.encode(Int64(number))
        } else {
            try container.encode(number)
        }
    }

    // MARK: - Convenience

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// MARK: - UnknownFields

/// The keys of a JSON object that a `Codable` type did not claim, kept so they survive a re-encode.
///
/// Decoding uses a dynamic key container rather than `[String: JSONValue]` directly because the
/// known keys have to be *subtracted*: decoding the whole object and then removing the typed fields
/// is the only way to be sure a field is unknown, since `CodingKeys` is not enumerable at runtime
/// in a form the compiler will hand back.
struct UnknownFields: Hashable {

    private(set) var values: [String: JSONValue]

    var isEmpty: Bool { values.isEmpty }

    init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    /// Decodes every key of the container except `known`.
    init(from decoder: any Decoder, excluding known: Set<String>) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var values: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            values[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.values = values
    }

    /// Writes the preserved keys back into `encoder`'s keyed container.
    ///
    /// A key that collides with one the type owns is dropped rather than written twice: the typed
    /// value is the one the app just edited, and emitting both would produce a duplicate JSON key.
    /// A collision can only happen if a future version of this app claims a field it used to
    /// preserve, in which case the typed value is exactly the right winner.
    func encode(to encoder: any Encoder, excluding known: Set<String>) throws {
        guard !isEmpty else { return }
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in values where !known.contains(key) {
            try container.encode(value, forKey: DynamicKey(stringValue: key))
        }
    }

    subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }
}

// MARK: - DynamicKey

/// A `CodingKey` for names that are not known at compile time.
struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
