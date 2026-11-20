import Foundation

/// Postup odesílání v UserDefaults. Klíče nesou jmenný prostor cíle, takže změna adresy, verze nebo
/// `receiverStateId` začíná znovu (nový cíl nikdy nedědí potvrzení z jiného). Neplatná hodnota = chybí.
public final class UserDefaultsPushProgress: PushProgress {
    private let defaults: UserDefaults
    private let namespace: String

    public init(defaults: UserDefaults = .standard, namespace: String) {
        self.defaults = defaults
        self.namespace = namespace
    }

    private func key(_ kind: String, _ stream: String, _ deviceId: String) -> String {
        "selfHostedPush.\(namespace).\(kind).\(stream).\(Sha256.hex(Data(deviceId.utf8)).prefix(16))"
    }

    public func cursor(stream: String, deviceId: String) -> Cursor? {
        guard let text = defaults.string(forKey: key("cursor", stream, deviceId)) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let row = Int64(parts[0]), row > 0, parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return Cursor(rowId: row, keySha256: String(parts[1]))
    }

    public func setCursor(_ cursor: Cursor?, stream: String, deviceId: String) {
        let k = key("cursor", stream, deviceId)
        if let c = cursor { defaults.set("\(c.rowId):\(c.keySha256)", forKey: k) } else { defaults.removeObject(forKey: k) }
    }

    public func dayHashes(stream: String, deviceId: String) -> [String: String] {
        guard let text = defaults.string(forKey: key("days", stream, deviceId)), let data = text.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public func setDayHashes(_ hashes: [String: String], stream: String, deviceId: String) {
        let k = key("days", stream, deviceId)
        if hashes.isEmpty { defaults.removeObject(forKey: k); return }
        guard let data = try? JSONEncoder().encode(hashes), let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: k)
    }
}

/// Jmenný prostor postupu: 12 bajtů SHA-256 z `sourceId`, adresy, verze a `receiverStateId` (jako Android). Token se nepočítá.
public enum PushNamespace {
    public static func make(sourceId: String, endpoint: String, version: String, receiverStateId: String) -> String {
        let input = [sourceId, endpoint, version, receiverStateId].joined(separator: "\u{0}")
        return String(Sha256.hex(Data(input.utf8)).prefix(24))
    }
}
