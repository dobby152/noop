import Foundation
import XCTest
@testable import WhoopPush

final class FakeSource: PushDataSource {
    var devices = ["strap-1"]
    var hr: [AppendRecord] = []
    var daily: [String: Double] = [:]          // den -> recovery
    var appendReads = 0

    func deviceIds() throws -> [String] { devices }
    func appendRecords(stream: String, deviceId: String, afterRowId: Int64?, limit: Int) throws -> [AppendRecord] {
        appendReads += 1
        return Array(hr.filter { $0.rowId > (afterRowId ?? 0) }.prefix(limit))
    }
    func appendRecordKey(stream: String, deviceId: String, rowId: Int64) throws -> [(String, JSONValue)]? {
        hr.first { $0.rowId == rowId }?.key
    }
    func mutableRecords(stream: String, deviceId: String, window: SelectorWindow) throws -> [MutableRecord] {
        guard stream == "dailyMetric", case let .day(from, to) = window else { return [] }
        let names = Registry.spec("dailyMetric")!.dataColumns
        return daily.filter { $0.key >= from && $0.key <= to }.sorted { $0.key < $1.key }.map { day, rec in
            MutableRecord(key: [("day", .string(day))], data: names.map { ($0, $0 == "recovery" ? JSONValue.double(rec) : .null) })
        }
    }
}

final class FakeTransport: PushTransport {
    var posted: [Batch] = []
    var failNext: PushFailure?
    var corruptAck = false
    func capabilities() throws -> PushCapabilities { PushCapabilities(receiverStateId: "5fc7b9a0-8055-4e49-a308-3a290f98d81a", streams: Registry.streamNames) }
    func post(_ batch: Batch) throws -> Data {
        if let f = failNext { failNext = nil; throw f }
        posted.append(batch)
        var d: [String: Any] = ["protocolVersion": "1.0", "batchId": batch.batchId, "stream": batch.stream, "deviceId": "strap-1",
                                "acceptedRows": corruptAck ? 0 : batch.recordCount, "status": "accepted"]
        d["endCursor"] = batch.endCursor.map { ["rowId": $0.rowId, "keySha256": $0.keySha256] as [String: Any] } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: d)
    }
}

final class PushCoordinatorTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    private var calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private let now = Date(timeIntervalSince1970: 1_795_003_200) // 2026-11-18 12:00 UTC

    private func make(_ s: FakeSource, _ t: FakeTransport, _ p: InMemoryProgress = InMemoryProgress()) -> PushCoordinator {
        PushCoordinator(source: s, transport: t, progress: p, sourceId: source, calendar: calendar, now: { self.now })
    }

    private func hr(_ n: Int, from: Int = 1) -> [AppendRecord] {
        (from..<(from + n)).map { AppendRecord(rowId: Int64($0), key: [("ts", .int(1000 + $0))], data: [("bpm", .int(60))]) }
    }

    func testAppendSendsThenAdvancesCursorAndThenSendsNothing() throws {
        let s = FakeSource(); s.hr = hr(3); let t = FakeTransport(); let p = InMemoryProgress(); let c = make(s, t, p)
        XCTAssertFalse(try c.pushAppend(stream: "hrSample", deviceId: "strap-1"))
        XCTAssertEqual(t.posted.count, 1)
        XCTAssertEqual(p.cursor(stream: "hrSample", deviceId: "strap-1")?.rowId, 3)
        XCTAssertFalse(try c.pushAppend(stream: "hrSample", deviceId: "strap-1"))
        XCTAssertEqual(t.posted.count, 1)
        s.hr += hr(2, from: 4)
        XCTAssertFalse(try c.pushAppend(stream: "hrSample", deviceId: "strap-1"))
        XCTAssertEqual(t.posted.count, 2)
        XCTAssertEqual(t.posted[1].recordCount, 2)
    }

    func testAppendReportsMoreWhenPageIsFull() throws {
        let s = FakeSource(); s.hr = hr(5001); let t = FakeTransport(); let c = make(s, t)
        XCTAssertTrue(try c.pushAppend(stream: "hrSample", deviceId: "strap-1"))
        XCTAssertEqual(t.posted[0].recordCount, 5000)
        XCTAssertFalse(try c.pushAppend(stream: "hrSample", deviceId: "strap-1"))
        XCTAssertEqual(t.posted[1].recordCount, 1)
    }

    func testCursorIsResetWhenSavedRowNoLongerMatches() throws {
        let s = FakeSource(); s.hr = hr(3); let t = FakeTransport(); let p = InMemoryProgress(); let c = make(s, t, p)
        _ = try c.pushAppend(stream: "hrSample", deviceId: "strap-1")
        // obnova databáze: stejné rowId, jiné záznamy
        s.hr = (1...3).map { AppendRecord(rowId: Int64($0), key: [("ts", .int(9000 + $0))], data: [("bpm", .int(70))]) }
        _ = try c.pushAppend(stream: "hrSample", deviceId: "strap-1")
        XCTAssertEqual(t.posted.count, 2)
        XCTAssertEqual(t.posted[1].recordCount, 3) // znovu od začátku
    }

    func testFailureLeavesCursorUnchangedAndRetryResendsIdenticalBatch() throws {
        let s = FakeSource(); s.hr = hr(2); let t = FakeTransport(); let p = InMemoryProgress(); let c = make(s, t, p)
        t.failNext = .http(503)
        XCTAssertThrowsError(try c.pushAppend(stream: "hrSample", deviceId: "strap-1")) { XCTAssertEqual($0 as? PushFailure, .http(503)) }
        XCTAssertNil(p.cursor(stream: "hrSample", deviceId: "strap-1"))
        _ = try c.pushAppend(stream: "hrSample", deviceId: "strap-1")
        XCTAssertEqual(t.posted.count, 1)
    }

    func testMismatchedAckIsAFailureAndKeepsProgress() throws {
        let s = FakeSource(); s.hr = hr(2); let t = FakeTransport(); t.corruptAck = true; let p = InMemoryProgress(); let c = make(s, t, p)
        XCTAssertThrowsError(try c.pushAppend(stream: "hrSample", deviceId: "strap-1")) { XCTAssertEqual($0 as? PushFailure, .badAcknowledgement) }
        XCTAssertNil(p.cursor(stream: "hrSample", deviceId: "strap-1"))
    }

    func testMutableBaselineThenNothingWhenUnchanged() throws {
        let s = FakeSource(); s.daily = ["2026-11-10": 50, "2026-11-17": 64]; let t = FakeTransport(); let c = make(s, t)
        XCTAssertEqual(try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1"), 1)
        XCTAssertEqual(t.posted.count, 1)
        XCTAssertEqual(t.posted[0].recordCount, 2)
        XCTAssertEqual(try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1"), 0)
        XCTAssertEqual(t.posted.count, 1)
    }

    func testMutableSendsOnlyTheSpanOfChangedDays() throws {
        let s = FakeSource(); s.daily = ["2026-11-06": 40, "2026-11-10": 50, "2026-11-17": 64]; let t = FakeTransport(); let c = make(s, t)
        _ = try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1")
        s.daily["2026-11-10"] = 55
        XCTAssertEqual(try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1"), 1)
        XCTAssertEqual(t.posted.count, 2)
        XCTAssertEqual(t.posted[1].recordCount, 1)
        // okno obsahuje jen změněný den
        let header = String(decoding: t.posted[1].body, as: UTF8.self).split(separator: "\n")[0]
        XCTAssertTrue(header.contains("\"startInclusive\":\"2026-11-10\""))
        XCTAssertTrue(header.contains("\"endExclusive\":\"2026-11-11\""))
    }

    func testFormerlyPopulatedDayNowEmptyIsSentAsEmptyWindow() throws {
        let s = FakeSource(); s.daily = ["2026-11-10": 50]; let t = FakeTransport(); let c = make(s, t)
        _ = try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1")
        s.daily = [:]
        XCTAssertEqual(try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1"), 1)
        XCTAssertEqual(t.posted[1].recordCount, 0)
    }

    func testMutableFailureDoesNotRecordHashesSoItRepeats() throws {
        let s = FakeSource(); s.daily = ["2026-11-17": 64]; let t = FakeTransport(); let c = make(s, t)
        t.failNext = .transport
        XCTAssertThrowsError(try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1"))
        XCTAssertEqual(try c.pushMutable(stream: "dailyMetric", deviceId: "strap-1"), 1)
        XCTAssertEqual(t.posted.count, 1)
    }

    func testRunOnceHonoursAdvertisedStreamsOnly() throws {
        let s = FakeSource(); s.hr = hr(1); s.daily = ["2026-11-17": 64]; let t = FakeTransport(); let c = make(s, t)
        let report = try c.runOnce(advertised: ["dailyMetric"])
        XCTAssertEqual(t.posted.map { $0.stream }, ["dailyMetric"])
        XCTAssertFalse(report.moreWork)
        XCTAssertEqual(s.appendReads, 0)
    }
}
