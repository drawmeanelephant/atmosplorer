import Foundation

/// A minimal JSON tree used as the default record value type for callers
/// that don't have a dedicated model for a lexicon.
///
/// Navigating a record body feels like the Zig side's json path helpers:
///
///     let value: ZatJSONValue = record.value
///     let text = value["embed"]?["external"]?["title"]?.stringValue
public enum ZatJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ZatJSONValue])
    case object([String: ZatJSONValue])
}

extension ZatJSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ZatJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ZatJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }
}

extension ZatJSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension ZatJSONValue: ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral,
    ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: ZatJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ZatJSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

public extension ZatJSONValue {
    /// Object member access; nil for non-objects or missing keys.
    subscript(key: String) -> ZatJSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Array index access; nil for non-arrays or out-of-range indices.
    subscript(index: Int) -> ZatJSONValue? {
        if case .array(let array) = self, array.indices.contains(index) {
            return array[index]
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [ZatJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: ZatJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Decode this value into a typed `Decodable` model, e.g.
    /// `record.value.decode(as: Post.self)`.
    func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
