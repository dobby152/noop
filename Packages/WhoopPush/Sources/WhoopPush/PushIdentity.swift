import Foundation

/// Identifikátory a otisky protokolu v1, zkopírované z Androidu (`PushProtocol.kt`).
public enum PushIdentity {
    public static let version = "1.0"

    /// SHA-256(stream LF deviceId LF kompaktní přirozený klíč v pořadí registru).
    public static func keyFingerprint(stream: String, deviceId: String, key: [(String, JSONValue)]) throws -> String {
        let json = try CanonicalJSON.string(.object(key), sortKeys: false)
        return Sha256.hex(Data("\(stream)\n\(deviceId)\n\(json)".utf8))
    }

    /// Řádek záznamu: kanonický JSON se seřazenými klíči a LF na konci.
    public static func recordLine(key: [(String, JSONValue)], data: [(String, JSONValue)]) throws -> Data {
        let value = JSONValue.object([("data", .object(data)), ("key", .object(key)), ("type", .string("record"))])
        return Data((try CanonicalJSON.string(value, sortKeys: true) + "\n").utf8)
    }

    /// Deterministické UUID (verze 5) z identity hlavičky a řádků záznamů. Stabilní při opakování.
    public static func stableUUID(identity: JSONValue, lines: [Data]) throws -> String {
        var input = try CanonicalJSON.data(identity, sortKeys: true)
        input.append(0x0a)
        for line in lines { input.append(line) }
        var bytes = Array(Sha256.hash(input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let h = Array(hex)
        func part(_ a: Int, _ b: Int) -> String { String(h[a..<b]) }
        return [part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32)].joined(separator: "-")
    }

    /// Místní otisk obsahu dne (nikdy se neposílá): SHA-256 přes předponu a bajtově seřazené řádky.
    public static func snapshotHash(stream: String, lines: [Data]) -> String {
        var input = Data("noop-push-day-hash\n\(version)\n\(stream)\n".utf8)
        for line in lines.sorted(by: { $0.lexicographicallyPrecedes($1) }) { input.append(line) }
        return Sha256.hex(input)
    }
}
