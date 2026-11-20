import Foundation

/// Zdroj dat (v aplikaci nad GRDB). Čtení musí vracet explicitní projekce sloupců v pořadí z `Registry`.
public protocol PushDataSource {
    func deviceIds() throws -> [String]
    func appendRecords(stream: String, deviceId: String, afterRowId: Int64?, limit: Int) throws -> [AppendRecord]
    /// Přirozený klíč řádku se zadaným `rowid` (kontrola kurzoru po obnově nebo úpravě databáze); `nil`, když řádek chybí.
    func appendRecordKey(stream: String, deviceId: String, rowId: Int64) throws -> [(String, JSONValue)]?
    func mutableRecords(stream: String, deviceId: String, window: SelectorWindow) throws -> [MutableRecord]
}

/// Doručení jedné dávky. Chyby se převádějí na `PushFailure`; odpověď se kontroluje až v koordinátoru.
public protocol PushTransport {
    func capabilities() throws -> PushCapabilities
    func post(_ batch: Batch) throws -> Data
}

/// Postup odesílání (kurzory a hashe dnů). Je to jen metadata, na straně přijímače se nic neukládá.
public protocol PushProgress: AnyObject {
    func cursor(stream: String, deviceId: String) -> Cursor?
    func setCursor(_ cursor: Cursor?, stream: String, deviceId: String)
    func dayHashes(stream: String, deviceId: String) -> [String: String]
    func setDayHashes(_ hashes: [String: String], stream: String, deviceId: String)
}

public final class InMemoryProgress: PushProgress {
    private var cursors: [String: Cursor] = [:]
    private var hashes: [String: [String: String]] = [:]
    public init() {}
    private func k(_ s: String, _ d: String) -> String { "\(s)\u{0}\(d)" }
    public func cursor(stream: String, deviceId: String) -> Cursor? { cursors[k(stream, deviceId)] }
    public func setCursor(_ cursor: Cursor?, stream: String, deviceId: String) { cursors[k(stream, deviceId)] = cursor }
    public func dayHashes(stream: String, deviceId: String) -> [String: String] { hashes[k(stream, deviceId)] ?? [:] }
    public func setDayHashes(_ h: [String: String], stream: String, deviceId: String) { hashes[k(stream, deviceId)] = h }
}

public struct PushReport: Equatable {
    public var batchesSent = 0
    public var moreWork = false
}

public final class PushCoordinator {
    public static let windowDays = 14

    private let source: PushDataSource
    private let transport: PushTransport
    private let progress: PushProgress
    private let sourceId: String
    private let calendar: Calendar
    private let now: () -> Date

    public init(source: PushDataSource, transport: PushTransport, progress: PushProgress, sourceId: String, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.source = source; self.transport = transport; self.progress = progress
        self.sourceId = sourceId; self.calendar = calendar; self.now = now
    }

    /// Jeden průchod: pro každé zařízení a každý nabízený proud jedna stránka přírůstků a jedno srovnání přepisovaných dnů.
    public func runOnce(advertised: [String]) throws -> PushReport {
        var report = PushReport()
        for device in try source.deviceIds() {
            for spec in Registry.all where advertised.contains(spec.name) {
                switch spec.delivery {
                case .append:
                    let before = progress.cursor(stream: spec.name, deviceId: device)
                    let more = try pushAppend(stream: spec.name, deviceId: device)
                    if progress.cursor(stream: spec.name, deviceId: device) != before { report.batchesSent += 1 }
                    if more { report.moreWork = true }
                case .replaceWindow:
                    report.batchesSent += try pushMutable(stream: spec.name, deviceId: device)
                }
            }
        }
        return report
    }

    // MARK: - Přírůstky

    /// Vrací `true`, když po této stránce zbývají další řádky.
    @discardableResult
    public func pushAppend(stream: String, deviceId: String) throws -> Bool {
        var saved = progress.cursor(stream: stream, deviceId: deviceId)
        if let s = saved {
            // Řádek pod uloženým kurzorem musí existovat a mít stejný otisk; jinak se databáze mezitím změnila a posíláme znovu od začátku.
            let key = try source.appendRecordKey(stream: stream, deviceId: deviceId, rowId: s.rowId)
            let fp = try key.map { try PushIdentity.keyFingerprint(stream: stream, deviceId: deviceId, key: $0) }
            if fp != s.keySha256 { saved = nil; progress.setCursor(nil, stream: stream, deviceId: deviceId) }
        }
        let page = try source.appendRecords(stream: stream, deviceId: deviceId, afterRowId: saved?.rowId, limit: BatchEncoder.maxRecords + 1)
        guard !page.isEmpty else { return false }
        let batch = try encode { try BatchEncoder.appendBatch(stream: stream, sourceId: sourceId, deviceId: deviceId, startCursor: saved, records: page) }
        try deliver(batch, deviceId: deviceId)
        progress.setCursor(batch.endCursor, stream: stream, deviceId: deviceId)
        return page.count > batch.recordCount
    }

    // MARK: - Přepisovaná data

    /// Vrací počet odeslaných částí (0, když se nic nezměnilo).
    @discardableResult
    public func pushMutable(stream: String, deviceId: String) throws -> Int {
        guard let spec = Registry.spec(stream), spec.delivery == .replaceWindow, let selector = spec.selector else { throw PushFailure.encoding }
        let today = calendar.startOfDay(for: now())
        let days = (0..<Self.windowDays).map { calendar.date(byAdding: .day, value: -(Self.windowDays - 1 - $0), to: today)! }
        let names = days.map(dayString)
        let full = try window(selector, from: days.first!, to: days.last!)

        let records = try source.mutableRecords(stream: stream, deviceId: deviceId, window: full)
        var byDay: [String: [MutableRecord]] = [:]
        for r in records { byDay[try dayOf(r, selector), default: []].append(r) }

        var hashes: [String: String] = [:]
        for d in names {
            let lines = try (byDay[d] ?? []).map { r in try encode { try PushIdentity.recordLine(key: r.key, data: r.data) } }
            hashes[d] = PushIdentity.snapshotHash(stream: stream, lines: lines)
        }

        let stored = progress.dayHashes(stream: stream, deviceId: deviceId)
        let changed: [Int]
        if stored.isEmpty {
            changed = Array(names.indices)
        } else {
            changed = names.indices.filter { i in
                let d = names[i]
                if let old = stored[d] { return old != hashes[d] }
                return !(byDay[d] ?? []).isEmpty
            }
        }
        guard let first = changed.first, let last = changed.last else {
            progress.setDayHashes(hashes, stream: stream, deviceId: deviceId)
            return 0
        }

        let spanWindow = try window(selector, from: days[first], to: days[last])
        let spanRecords = names[first...last].flatMap { byDay[$0] ?? [] }
        let batches = try encode { try BatchEncoder.replaceWindowBatches(stream: stream, sourceId: sourceId, deviceId: deviceId, window: spanWindow, records: spanRecords) }
        for b in batches { try deliver(b, deviceId: deviceId) }
        progress.setDayHashes(hashes, stream: stream, deviceId: deviceId)
        return batches.count
    }

    // MARK: - Pomocné

    private func deliver(_ batch: Batch, deviceId: String) throws {
        let response = try transport.post(batch)
        guard PushAck.matches(response, batch: batch, deviceId: deviceId) else { throw PushFailure.badAcknowledgement }
    }

    private func encode<T>(_ f: () throws -> T) throws -> T {
        do { return try f() } catch let e as PushFailure { throw e } catch { throw PushFailure.encoding }
    }

    private func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func window(_ selector: StreamSpec.Selector, from: Date, to: Date) throws -> SelectorWindow {
        switch selector {
        case .day: return .day(from: dayString(from), toInclusive: dayString(to))
        case .startTs:
            let end = calendar.date(byAdding: .day, value: 1, to: to)!
            return .startTs(from: Int64(from.timeIntervalSince1970), toExclusive: Int64(end.timeIntervalSince1970))
        }
    }

    private func dayOf(_ r: MutableRecord, _ selector: StreamSpec.Selector) throws -> String {
        switch (selector, r.key.first?.1) {
        case let (.day, .string(d)?): return d
        case let (.startTs, .int(ts)?): return dayString(Date(timeIntervalSince1970: TimeInterval(ts)))
        default: throw PushFailure.encoding
        }
    }
}
