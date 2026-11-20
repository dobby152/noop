import Foundation
import XCTest
@testable import WhoopPush

final class BatchEncoderTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"

    func testAppendBatchMatchesIndependentReference() throws {
        let records = [
            AppendRecord(rowId: 5, key: [("ts", .int(100))], data: [("bpm", .int(61))]),
            AppendRecord(rowId: 6, key: [("ts", .int(101))], data: [("bpm", .int(62))]),
        ]
        let batch = try BatchEncoder.appendBatch(stream: "hrSample", sourceId: source, deviceId: "strap-1", startCursor: nil, records: records)
        XCTAssertEqual(batch.batchId, "0595ebfa-cc6d-5b87-833a-01839bff3ccf")
        XCTAssertEqual(batch.recordCount, 2)
        XCTAssertEqual(batch.endCursor, Cursor(rowId: 6, keySha256: "d240d3c03be1f5ab477fbc76ef3b9a67fc5558019cdc7c49868ee12f5594bf0f"))
        let lines = String(decoding: batch.body, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(lines[0]), "{\"batchId\":\"0595ebfa-cc6d-5b87-833a-01839bff3ccf\",\"delivery\":\"append\",\"deviceId\":\"strap-1\",\"endCursor\":{\"keySha256\":\"d240d3c03be1f5ab477fbc76ef3b9a67fc5558019cdc7c49868ee12f5594bf0f\",\"rowId\":6},\"protocolVersion\":\"1.0\",\"recordCount\":2,\"sourceId\":\"\(source)\",\"startCursor\":null,\"stream\":\"hrSample\",\"type\":\"batch\"}")
        XCTAssertEqual(String(lines[1]), "{\"data\":{\"bpm\":61},\"key\":{\"ts\":100},\"type\":\"record\"}")
        XCTAssertEqual(lines.count, 4) // hlavička, 2 záznamy, prázdný zbytek po závěrečném LF
    }

    func testAppendRejectsEmptyUnorderedAndWrongColumns() {
        XCTAssertThrowsError(try BatchEncoder.appendBatch(stream: "hrSample", sourceId: source, deviceId: "d", startCursor: nil, records: []))
        let unordered = [
            AppendRecord(rowId: 6, key: [("ts", .int(1))], data: [("bpm", .int(1))]),
            AppendRecord(rowId: 5, key: [("ts", .int(2))], data: [("bpm", .int(1))]),
        ]
        XCTAssertThrowsError(try BatchEncoder.appendBatch(stream: "hrSample", sourceId: source, deviceId: "d", startCursor: nil, records: unordered))
        let wrongData = [AppendRecord(rowId: 1, key: [("ts", .int(1))], data: [("hr", .int(1))])]
        XCTAssertThrowsError(try BatchEncoder.appendBatch(stream: "hrSample", sourceId: source, deviceId: "d", startCursor: nil, records: wrongData))
        XCTAssertThrowsError(try BatchEncoder.appendBatch(stream: "nope", sourceId: source, deviceId: "d", startCursor: nil, records: wrongData))
    }

    func testReplaceWindowBatchMatchesIndependentReference() throws {
        let record = MutableRecord(
            key: [("day", .string("2026-11-17"))],
            data: dailyMetricData(recovery: 64.0)
        )
        let window = SelectorWindow.day(from: "2026-11-05", toInclusive: "2026-11-18")
        let batches = try BatchEncoder.replaceWindowBatches(stream: "dailyMetric", sourceId: source, deviceId: "strap-1", window: window, records: [record])
        XCTAssertEqual(batches.count, 1)
        let b = batches[0]
        XCTAssertEqual(b.replacementId, "a5353490-8257-52ec-b1c8-cdfc1ee5f090")
        XCTAssertEqual(b.batchId, "86e8c763-cf18-5cab-ba23-6786992b507e")
        XCTAssertNil(b.endCursor)
        let first = String(decoding: b.body, as: UTF8.self).split(separator: "\n")[0]
        XCTAssertEqual(String(first), "{\"batchId\":\"86e8c763-cf18-5cab-ba23-6786992b507e\",\"delivery\":\"replace_window\",\"deviceId\":\"strap-1\",\"endCursor\":null,\"protocolVersion\":\"1.0\",\"recordCount\":1,\"sourceId\":\"\(source)\",\"startCursor\":null,\"stream\":\"dailyMetric\",\"type\":\"batch\",\"window\":{\"endExclusive\":\"2026-11-19\",\"part\":1,\"parts\":1,\"replacementId\":\"a5353490-8257-52ec-b1c8-cdfc1ee5f090\",\"selector\":\"day\",\"startInclusive\":\"2026-11-05\"}}")
    }

    func testEmptyWindowIsOneZeroRecordPart() throws {
        let window = SelectorWindow.day(from: "2026-11-05", toInclusive: "2026-11-18")
        let batches = try BatchEncoder.replaceWindowBatches(stream: "dailyMetric", sourceId: source, deviceId: "strap-1", window: window, records: [])
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].recordCount, 0)
    }

    func testReplaceWindowRejectsDuplicateKeys() {
        let r = MutableRecord(key: [("day", .string("2026-11-17"))], data: dailyMetricData(recovery: 1))
        let window = SelectorWindow.day(from: "2026-11-05", toInclusive: "2026-11-18")
        XCTAssertThrowsError(try BatchEncoder.replaceWindowBatches(stream: "dailyMetric", sourceId: source, deviceId: "d", window: window, records: [r, r]))
    }

    func testLargeWindowSplitsIntoPartsWithSameReplacementId() throws {
        let window = SelectorWindow.startTs(from: 0, toExclusive: 10_000_000)
        let records = (0..<5001).map { i in
            MutableRecord(key: [("startTs", .int(i))], data: sleepData(endTs: i + 1))
        }
        let batches = try BatchEncoder.replaceWindowBatches(stream: "sleepSession", sourceId: source, deviceId: "d", window: window, records: records)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(Set(batches.map { $0.replacementId }).count, 1)
        XCTAssertEqual(batches.map { $0.part }, [1, 2])
        XCTAssertEqual(batches.map { $0.parts }, [2, 2])
        XCTAssertEqual(batches.map { $0.recordCount }, [5000, 1])
        XCTAssertTrue(batches[0].batchId != batches[1].batchId)
    }

    private func dailyMetricData(recovery: Double) -> [(String, JSONValue)] {
        let names = ["totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances", "restingHr", "avgHrv", "recovery", "strain",
                     "exerciseCount", "spo2Pct", "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir"]
        return names.map { ($0, $0 == "recovery" ? JSONValue.double(recovery) : JSONValue.null) }
    }

    private func sleepData(endTs: Int) -> [(String, JSONValue)] {
        [("endTs", .int(endTs)), ("efficiency", .null), ("restingHr", .null), ("avgHrv", .null), ("stagesJSON", .null),
         ("userEdited", .bool(false)), ("startTsAdjusted", .null), ("motionJSON", .null), ("sleepStateJSON", .null), ("stagingSparse", .null)]
    }
}
