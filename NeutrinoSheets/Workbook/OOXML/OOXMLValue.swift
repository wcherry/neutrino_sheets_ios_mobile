import Foundation

// MARK: - OOXMLValue

/// A JSON document as a value, which is what the spreadsheet codec moves.
///
/// The codec's door is the stored `sheet.json` envelope rather than a typed workbook (see
/// ``XlsxCodec``), so it has to read and write arbitrary JSON: the parts of a spreadsheet this
/// module *maps* are typed on the way through, and the parts it only *carries* — charts, the
/// conditional-format kinds OOXML cannot express, anything a later web release adds — must survive
/// without the codec knowing their shape.
///
/// Backed by `JSONSerialization` at the edges rather than a hand-written parser: Foundation already
/// has the parser, and the value type is here for the code that walks the result, which is far more
/// legible against an enum than against `Any`.
enum OOXMLValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OOXMLValue])
    case object([String: OOXMLValue])

    // MARK: - Accessors

var stringValue: String? {
        switch self {
        case .string(let value): return value
        // A cell's `raw` is a string on the wire, but a workbook that has been through another tool
        // can put a bare number where one is expected. Reading it as its text is what the editor
        // does with the same value.
        case .number(let value): return OOXMLValue.numberText(value)
        case .bool(let value):   return value ? "true" : "false"
        default: return nil
        }
    }

var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

var intValue: Int? {
        guard let double = doubleValue, double.isFinite else { return nil }
        return Int(double)
    }

var boolValue: Bool? {
        switch self {
        case .bool(let value):   return value
        case .number(let value): return value != 0
        default: return nil
        }
    }

var arrayValue: [OOXMLValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

var objectValue: [String: OOXMLValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

var isNull: Bool { self == .null }

    /// A member of this object, or nil when the value is not an object or has no such key.
subscript(key: String) -> OOXMLValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// An element of this array, or nil when the value is not an array or the index is out of range.
    ///
    /// Out of range rather than a trap because every index into a parsed document comes from data:
    /// the workbook being read decides how many sheets there are, not the code reading it.
subscript(index: Int) -> OOXMLValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }

    // MARK: - Parsing

static func parse(_ data: Data) -> OOXMLValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return OOXMLValue(any)
    }

static func parse(_ text: String) -> OOXMLValue? { parse(Data(text.utf8)) }

    /// Serialises the value, with object keys in sorted order so two encodings of the same workbook
    /// are byte-identical — the same reason ``ZipArchive`` fixes its timestamps.
func serialized() -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        // `JSON.stringify` leaves `/` alone, so matching it keeps an extras payload written here
        // byte-identical to the same payload written on the web. Guarded rather than declared
        // because the package names only an iOS platform, which leaves macOS — where the tests
        // build — at a deployment target that predates the option.
        if #available(iOS 13.0, macOS 10.15, *) { options.insert(.withoutEscapingSlashes) }
        return (try? JSONSerialization.data(withJSONObject: foundationObject, options: options))
            ?? Data("null".utf8)
    }

func serializedString() -> String { String(decoding: serialized(), as: UTF8.self) }

    // MARK: - Bridging

    init?(_ any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // `NSNumber` does not distinguish a JSON `true` from a `1` by its type, only by the
            // ObjC type encoding underneath it. Booleans have to be recognised here or every flag
            // in a carried payload comes back as a number and re-serialises as one.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.compactMap(OOXMLValue.init))
        case let object as [String: Any]:
            var members: [String: OOXMLValue] = [:]
            for (key, value) in object {
                guard let converted = OOXMLValue(value) else { continue }
                members[key] = converted
            }
            self = .object(members)
        default:
            return nil
        }
    }

    var foundationObject: Any {
        switch self {
        case .null:               return NSNull()
        case .bool(let value):    return value
        case .number(let value):  return OOXMLValue.foundationNumber(value)
        case .string(let value):  return value
        case .array(let values):  return values.map(\.foundationObject)
        case .object(let members): return members.mapValues(\.foundationObject)
        }
    }

    /// A double as the narrowest thing that round-trips: an integral value serialises as `3` rather
    /// than `3.0`, which is what the web writes and what the editor compares against.
    private static func foundationNumber(_ value: Double) -> Any {
        guard value.isFinite else { return 0 }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return Int(value) }
        return value
    }

    /// The text form of a number, integral values without a fractional part.
    static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return String(Int(value)) }
        return String(value)
    }
}

// MARK: - Building

extension OOXMLValue {

    /// An object with every nil member dropped, which is the sparse shape the web app writes and
    /// the codec has to reproduce: a cell that is only bold stores `{"fontWeight":"bold"}`.
    static func object(dropping members: [String: OOXMLValue?]) -> OOXMLValue {
        var out: [String: OOXMLValue] = [:]
        for (key, value) in members {
            guard let value else { continue }
            out[key] = value
        }
        return .object(out)
    }

    /// Convenience for a member that is only written when the string is non-nil and non-empty.
    static func text(_ value: String?) -> OOXMLValue? {
        guard let value, !value.isEmpty else { return nil }
        return .string(value)
    }
}
