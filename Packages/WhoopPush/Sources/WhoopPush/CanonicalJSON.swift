import Foundation

/// Hodnota JSON s uspořádanými objekty (pořadí klíčů je součástí protokolu, viz PUSH_PROTOCOL.md).
public indirect enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (l: JSONValue, r: JSONValue) -> Bool {
        switch (l, r) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public static func int(_ v: Int) -> JSONValue { .int(Int64(v)) }
}

/// Stejný zápis jako Android `PushProtocol.canonicalJson` / `orderedObjectJson`.
public enum CanonicalJSON {
    public static func string(_ value: JSONValue, sortKeys: Bool) throws -> String {
        var out = ""
        try append(value, sortKeys: sortKeys, to: &out)
        return out
    }

    public static func data(_ value: JSONValue, sortKeys: Bool) throws -> Data {
        Data(try string(value, sortKeys: sortKeys).utf8)
    }

    private static func append(_ value: JSONValue, sortKeys: Bool, to out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += try JavaDouble.checked(d)
        case .string(let s): appendQuoted(s, to: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                try append(item, sortKeys: sortKeys, to: &out)
            }
            out += "]"
        case .object(let pairs):
            // Kotlin `sortedBy` řadí String podle UTF-16 jednotek.
            let ordered = sortKeys ? pairs.sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) } : pairs
            out += "{"
            for (i, pair) in ordered.enumerated() {
                if i > 0 { out += "," }
                appendQuoted(pair.0, to: &out)
                out += ":"
                try append(pair.1, sortKeys: sortKeys, to: &out)
            }
            out += "}"
        }
    }

    private static func appendQuoted(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }
}
