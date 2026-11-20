import Foundation

/// Potvrzení dávky. Platí jen přesná shoda všech členů; jinak je to nepodařené doručení i při HTTP 2xx.
public enum PushAck {
    public static func matches(_ data: Data, batch: Batch, deviceId: String) -> Bool {
        guard data.count <= 16 * 1024,
              let any = try? JSONSerialization.jsonObject(with: data),
              let o = any as? [String: Any],
              o["protocolVersion"] as? String == PushIdentity.version,
              o["batchId"] as? String == batch.batchId,
              o["stream"] as? String == batch.stream,
              o["deviceId"] as? String == deviceId,
              o["status"] as? String == "accepted",
              (o["acceptedRows"] as? NSNumber)?.intValue == batch.recordCount,
              (o["acceptedRows"] is NSNumber)
        else { return false }
        guard let cursor = o["endCursor"] else { return false }
        if let expected = batch.endCursor {
            guard let c = cursor as? [String: Any],
                  (c["rowId"] as? NSNumber)?.int64Value == expected.rowId,
                  c["keySha256"] as? String == expected.keySha256 else { return false }
            return true
        }
        return cursor is NSNull
    }
}

public struct PushCapabilities: Equatable {
    public let receiverStateId: String
    public let streams: [String]

    public enum Failure: Error, Equatable { case tooLarge, malformed, unsupportedVersion, unknownStream, duplicateStream }

    /// Fail-closed: cokoli neplatného vrátí chybu dřív, než se otevře databáze nebo odešlou data.
    public static func parse(_ data: Data) throws -> PushCapabilities {
        guard data.count <= 16 * 1024 else { throw Failure.tooLarge }
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any],
              o["type"] as? String == "capabilities", let version = o["protocolVersion"] as? String,
              let stateId = o["receiverStateId"] as? String, let streams = o["streams"] as? [String]
        else { throw Failure.malformed }
        guard version == PushIdentity.version else { throw Failure.unsupportedVersion }
        guard UUID(uuidString: stateId) != nil, stateId == stateId.lowercased() else { throw Failure.malformed }
        guard Set(streams).count == streams.count else { throw Failure.duplicateStream }
        guard streams.allSatisfy({ Registry.spec($0) != nil }) else { throw Failure.unknownStream }
        return PushCapabilities(receiverStateId: stateId, streams: streams)
    }
}
