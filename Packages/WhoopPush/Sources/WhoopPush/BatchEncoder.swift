import Foundation

public struct Cursor: Equatable {
    public let rowId: Int64
    public let keySha256: String
    public init(rowId: Int64, keySha256: String) { self.rowId = rowId; self.keySha256 = keySha256 }
    var json: JSONValue { .object([("keySha256", .string(keySha256)), ("rowId", .int(rowId))]) }
}

public struct AppendRecord {
    public let rowId: Int64
    public let key: [(String, JSONValue)]
    public let data: [(String, JSONValue)]
    public init(rowId: Int64, key: [(String, JSONValue)], data: [(String, JSONValue)]) { self.rowId = rowId; self.key = key; self.data = data }
}

public struct MutableRecord {
    public let key: [(String, JSONValue)]
    public let data: [(String, JSONValue)]
    public init(key: [(String, JSONValue)], data: [(String, JSONValue)]) { self.key = key; self.data = data }
}

/// Okno přepisovaných dat. Dny jsou `YYYY-MM-DD`, časy Unix sekundy; konec je vždy výlučný.
public enum SelectorWindow: Equatable {
    case day(from: String, toInclusive: String)
    case startTs(from: Int64, toExclusive: Int64)

    var selector: StreamSpec.Selector {
        switch self {
        case .day: return .day
        case .startTs: return .startTs
        }
    }

    func bounds() throws -> [(String, JSONValue)] {
        switch self {
        case let .day(from, toInclusive):
            return [("endExclusive", .string(try Self.plusOneDay(toInclusive))), ("selector", .string("day")), ("startInclusive", .string(from))]
        case let .startTs(from, toExclusive):
            return [("endExclusive", .int(toExclusive)), ("selector", .string("startTs")), ("startInclusive", .int(from))]
        }
    }

    private static func plusOneDay(_ day: String) throws -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day), let next = cal.date(byAdding: .day, value: 1, to: d) else { throw PushProtocolError.invalidDay(day) }
        return f.string(from: next)
    }
}

public struct Batch {
    public let stream: String
    public let batchId: String
    public let body: Data
    public let recordCount: Int
    public let endCursor: Cursor?
    public let replacementId: String?
    public let part: Int?
    public let parts: Int?
}

public enum PushProtocolError: Error, Equatable {
    case emptyAppendBatch
    case unorderedRecords
    case invalidColumns(String)
    case unknownStream(String)
    case wrongDelivery(String)
    case duplicateKey
    case recordTooLarge
    case invalidDay(String)
}

public enum BatchEncoder {
    public static let maxRecords = 5000
    public static let maxBodyBytes = 4 * 1024 * 1024
    private static let placeholder = "00000000-0000-0000-0000-000000000000"

    public static func appendBatch(stream: String, sourceId: String, deviceId: String, startCursor: Cursor?, records: [AppendRecord]) throws -> Batch {
        let spec = try spec(stream, .append)
        guard !records.isEmpty else { throw PushProtocolError.emptyAppendBatch }
        for (a, b) in zip(records, records.dropFirst()) where a.rowId >= b.rowId { throw PushProtocolError.unorderedRecords }
        for r in records { try validate(spec, key: r.key, data: r.data) }

        var lines: [Data] = []
        var bytes = 0
        var end: Cursor?
        for r in records.prefix(maxRecords) {
            let line = try PushIdentity.recordLine(key: r.key, data: r.data)
            let candidateEnd = Cursor(rowId: r.rowId, keySha256: try PushIdentity.keyFingerprint(stream: stream, deviceId: deviceId, key: r.key))
            let header = try appendHeader(stream, sourceId, deviceId, startCursor, candidateEnd, lines.count + 1, placeholder)
            if header.count + bytes + line.count > maxBodyBytes { break }
            lines.append(line); bytes += line.count; end = candidateEnd
        }
        guard let endCursor = end else { throw PushProtocolError.recordTooLarge }
        let identity = appendIdentity(stream, sourceId, deviceId, startCursor, endCursor, lines.count)
        let batchId = try PushIdentity.stableUUID(identity: identity, lines: lines)
        var body = try appendHeader(stream, sourceId, deviceId, startCursor, endCursor, lines.count, batchId)
        for l in lines { body.append(l) }
        return Batch(stream: stream, batchId: batchId, body: body, recordCount: lines.count, endCursor: endCursor, replacementId: nil, part: nil, parts: nil)
    }

    public static func replaceWindowBatches(stream: String, sourceId: String, deviceId: String, window: SelectorWindow, records: [MutableRecord]) throws -> [Batch] {
        let spec = try spec(stream, .replaceWindow)
        guard window.selector == spec.selector else { throw PushProtocolError.wrongDelivery(stream) }
        for r in records { try validate(spec, key: r.key, data: r.data) }
        var seen = Set<String>()
        for r in records where !seen.insert(try CanonicalJSON.string(.object(r.key), sortKeys: false)).inserted { throw PushProtocolError.duplicateKey }

        let lines = try records.map { try PushIdentity.recordLine(key: $0.key, data: $0.data) }
        let bounds = try window.bounds()
        let replacementIdentity = JSONValue.object([
            ("deviceId", .string(deviceId)), ("delivery", .string("replace_window")), ("protocolVersion", .string(PushIdentity.version)),
            ("sourceId", .string(sourceId)), ("stream", .string(stream)), ("window", .object(bounds)),
        ])
        let replacementId = try PushIdentity.stableUUID(identity: replacementIdentity, lines: lines)

        var chunks: [[Data]] = []
        var current: [Data] = []
        var currentBytes = 0
        let maxInt = Int(Int32.max)
        for line in lines {
            let next = current.count + 1
            let conservative = try mutableHeader(stream, sourceId, deviceId, bounds, replacementId, maxInt, maxInt, next, placeholder)
            if next > maxRecords || conservative.count + currentBytes + line.count > maxBodyBytes {
                if current.isEmpty { throw PushProtocolError.recordTooLarge }
                chunks.append(current); current = []; currentBytes = 0
            }
            let one = try mutableHeader(stream, sourceId, deviceId, bounds, replacementId, maxInt, maxInt, 1, placeholder)
            if one.count + line.count > maxBodyBytes { throw PushProtocolError.recordTooLarge }
            current.append(line); currentBytes += line.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }

        let parts = chunks.count
        return try chunks.enumerated().map { index, partLines in
            let part = index + 1
            let identity = mutableIdentity(stream, sourceId, deviceId, bounds, replacementId, part, parts, partLines.count)
            let batchId = try PushIdentity.stableUUID(identity: identity, lines: partLines)
            var body = try mutableHeader(stream, sourceId, deviceId, bounds, replacementId, part, parts, partLines.count, batchId)
            for l in partLines { body.append(l) }
            return Batch(stream: stream, batchId: batchId, body: body, recordCount: partLines.count, endCursor: nil, replacementId: replacementId, part: part, parts: parts)
        }
    }

    // MARK: - Hlavičky (pole jsou stejná jako v Androidu, kanonický zápis seřadí klíče)

    private static func appendIdentity(_ stream: String, _ source: String, _ device: String, _ start: Cursor?, _ end: Cursor, _ count: Int) -> JSONValue {
        .object([
            ("delivery", .string("append")), ("deviceId", .string(device)), ("endCursor", end.json),
            ("protocolVersion", .string(PushIdentity.version)), ("recordCount", .int(count)), ("sourceId", .string(source)),
            ("startCursor", start?.json ?? .null), ("stream", .string(stream)), ("type", .string("batch")),
        ])
    }

    private static func line(_ identity: JSONValue, batchId: String) throws -> Data {
        guard case var .object(pairs) = identity else { return Data() }
        pairs.append(("batchId", .string(batchId)))
        return Data((try CanonicalJSON.string(.object(pairs), sortKeys: true) + "\n").utf8)
    }

    private static func appendHeader(_ stream: String, _ source: String, _ device: String, _ start: Cursor?, _ end: Cursor, _ count: Int, _ batchId: String) throws -> Data {
        try line(appendIdentity(stream, source, device, start, end, count), batchId: batchId)
    }

    private static func mutableIdentity(_ stream: String, _ source: String, _ device: String, _ bounds: [(String, JSONValue)], _ replacementId: String, _ part: Int, _ parts: Int, _ count: Int) -> JSONValue {
        .object([
            ("delivery", .string("replace_window")), ("deviceId", .string(device)), ("endCursor", .null),
            ("protocolVersion", .string(PushIdentity.version)), ("recordCount", .int(count)), ("sourceId", .string(source)),
            ("startCursor", .null), ("stream", .string(stream)), ("type", .string("batch")),
            ("window", .object(bounds + [("part", .int(part)), ("parts", .int(parts)), ("replacementId", .string(replacementId))])),
        ])
    }

    private static func mutableHeader(_ stream: String, _ source: String, _ device: String, _ bounds: [(String, JSONValue)], _ replacementId: String, _ part: Int, _ parts: Int, _ count: Int, _ batchId: String) throws -> Data {
        try line(mutableIdentity(stream, source, device, bounds, replacementId, part, parts, count), batchId: batchId)
    }

    // MARK: - Kontroly

    private static func spec(_ stream: String, _ delivery: StreamSpec.Delivery) throws -> StreamSpec {
        guard let s = Registry.spec(stream) else { throw PushProtocolError.unknownStream(stream) }
        guard s.delivery == delivery else { throw PushProtocolError.wrongDelivery(stream) }
        return s
    }

    private static func validate(_ spec: StreamSpec, key: [(String, JSONValue)], data: [(String, JSONValue)]) throws {
        guard key.map({ $0.0 }) == spec.keyColumns else { throw PushProtocolError.invalidColumns("\(spec.name) key") }
        guard data.map({ $0.0 }) == spec.dataColumns else { throw PushProtocolError.invalidColumns("\(spec.name) data") }
    }
}
