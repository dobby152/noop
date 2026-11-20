import Foundation
import GRDB
import XCTest
import WhoopPush
import WhoopStore
@testable import WhoopPushStore

final class GRDBPushSourceTests: XCTestCase {
    private func makeSource() async throws -> (GRDBPushSource, any DatabaseWriter) {
        let store = try await WhoopStore.inMemory()
        let writer = store.registryWriter
        return (GRDBPushSource(reader: writer), writer)
    }

    private func sql(_ w: any DatabaseWriter, _ statements: [String]) throws {
        try w.write { db in for s in statements { try db.execute(sql: s) } }
    }

    func testAppendReadsAfterRowIdInInsertionOrderWithLimit() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('d', 300, 70)",
                    "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('d', 100, 60)",   // starší měření vložené později
                    "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('d', 200, 65)",
                    "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('other', 1, 1)"])
        let all = try src.appendRecords(stream: "hrSample", deviceId: "d", afterRowId: nil, limit: 10)
        XCTAssertEqual(all.map { $0.rowId }, [1, 2, 3])
        XCTAssertEqual(all.map { $0.key[0].1 }, [.int(300), .int(100), .int(200)])
        XCTAssertEqual(all[0].data[0].0, "bpm")
        let page = try src.appendRecords(stream: "hrSample", deviceId: "d", afterRowId: 1, limit: 1)
        XCTAssertEqual(page.map { $0.rowId }, [2])
    }

    func testAppendRecordKeyForCursorValidation() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('d', 100, 60)"])
        XCTAssertEqual(try src.appendRecordKey(stream: "hrSample", deviceId: "d", rowId: 1)?.first?.1, .int(100))
        XCTAssertNil(try src.appendRecordKey(stream: "hrSample", deviceId: "d", rowId: 99))
        XCTAssertNil(try src.appendRecordKey(stream: "hrSample", deviceId: "other", rowId: 1))
    }

    func testColumnsFollowRegistryOrderAndMissingColumnsAreNull() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO rrInterval (deviceId, ts, rrMs, seq) VALUES ('d', 5, 812, 0)"])
        let r = try src.appendRecords(stream: "rrInterval", deviceId: "d", afterRowId: nil, limit: 5)[0]
        XCTAssertEqual(r.key.map { $0.0 }, ["ts", "rrMs", "seq"])
        XCTAssertEqual(r.data.map { $0.0 }, ["ord", "srcChannel", "tsSuspect"])
        XCTAssertEqual(r.data.map { $0.1 }, [.null, .null, .null])
    }

    func testBooleanColumnsBecomeJSONBooleans() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES ('d', 1, 80.5, 4000, 1)",
                    "INSERT INTO battery (deviceId, ts, soc, mv) VALUES ('d', 2, 79.0, 3990)"])
        let rows = try src.appendRecords(stream: "battery", deviceId: "d", afterRowId: nil, limit: 5)
        XCTAssertEqual(rows[0].data.map { $0.1 }, [.double(80.5), .int(4000), .bool(true)])
        XCTAssertEqual(rows[1].data.map { $0.1 }, [.double(79.0), .int(3990), .null])
    }

    func testStorageClassDecidesIntegerVersusDouble() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO gravitySample (deviceId, ts, x, y, z) VALUES ('d', 1, 0.25, 1, -0.5)"])
        let r = try src.appendRecords(stream: "gravitySample", deviceId: "d", afterRowId: nil, limit: 5)[0]
        XCTAssertEqual(r.data.prefix(3).map { $0.1 }, [.double(0.25), .double(1.0), .double(-0.5)])
    }

    func testDailyMetricWindowIsInclusiveOfBothDays() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('d', '2026-11-04', 10)",
                    "INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('d', '2026-11-05', 20)",
                    "INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('d', '2026-11-18', 30)",
                    "INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('d', '2026-11-19', 40)"])
        let rows = try src.mutableRecords(stream: "dailyMetric", deviceId: "d", window: .day(from: "2026-11-05", toInclusive: "2026-11-18"))
        XCTAssertEqual(rows.map { $0.key[0].1 }, [.string("2026-11-05"), .string("2026-11-18")])
        XCTAssertEqual(rows[0].data.map { $0.0 }, Registry.spec("dailyMetric")!.dataColumns)
    }

    func testStartTsWindowIsHalfOpenAndWorkoutRouteIsNullWhenColumnIsAbsent() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('d', 99, 120, 'run', 'auto')",
                    "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('d', 100, 200, 'run', 'auto')",
                    "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('d', 199, 300, 'lift', 'manual')",
                    "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('d', 200, 300, 'run', 'auto')"])
        let rows = try src.mutableRecords(stream: "workout", deviceId: "d", window: .startTs(from: 100, toExclusive: 200))
        XCTAssertEqual(rows.map { $0.key[0].1 }, [.int(100), .int(199)])
        let route = rows[0].data.first { $0.0 == "routePolyline" }?.1
        XCTAssertEqual(route, .null)
        XCTAssertEqual(rows[0].data.first { $0.0 == "endTs" }?.1, .int(200))
    }

    func testSleepSessionBooleanMapping() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES ('d', 150, 400, 1)"])
        let r = try src.mutableRecords(stream: "sleepSession", deviceId: "d", window: .startTs(from: 100, toExclusive: 200))[0]
        XCTAssertEqual(r.data.first { $0.0 == "userEdited" }?.1, .bool(true))
        XCTAssertEqual(r.data.first { $0.0 == "stagingSparse" }?.1, .null)
    }

    func testDeviceIdsUnionOfRegistryAndStreamTables() async throws {
        let (src, w) = try await makeSource()
        try sql(w, ["INSERT INTO device (id) VALUES ('registered')",
                    "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('from-samples', 1, 60)",
                    "INSERT INTO device (id) VALUES ('')"])
        XCTAssertEqual(Set(try src.deviceIds()), ["registered", "from-samples"])
    }
}
