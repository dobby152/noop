import Foundation
import XCTest
@testable import WhoopPush

final class AckTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"

    private func batch() throws -> Batch {
        try BatchEncoder.appendBatch(stream: "hrSample", sourceId: source, deviceId: "strap-1", startCursor: nil,
                                     records: [AppendRecord(rowId: 5, key: [("ts", .int(100))], data: [("bpm", .int(61))])])
    }

    private func ack(_ b: Batch, tweak: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var d: [String: Any] = [
            "protocolVersion": "1.0", "batchId": b.batchId, "stream": b.stream, "deviceId": "strap-1",
            "endCursor": ["rowId": b.endCursor!.rowId, "keySha256": b.endCursor!.keySha256],
            "acceptedRows": b.recordCount, "status": "accepted",
        ]
        tweak(&d)
        return try! JSONSerialization.data(withJSONObject: d)
    }

    func testExactAckAccepted() throws {
        let b = try batch()
        XCTAssertTrue(PushAck.matches(ack(b), batch: b, deviceId: "strap-1"))
    }

    func testAnyMismatchIsFailedDelivery() throws {
        let b = try batch()
        XCTAssertFalse(PushAck.matches(ack(b) { $0["acceptedRows"] = 0 }, batch: b, deviceId: "strap-1"))
        XCTAssertFalse(PushAck.matches(ack(b) { $0["status"] = "queued" }, batch: b, deviceId: "strap-1"))
        XCTAssertFalse(PushAck.matches(ack(b) { $0["batchId"] = "00000000-0000-5000-8000-000000000000" }, batch: b, deviceId: "strap-1"))
        XCTAssertFalse(PushAck.matches(ack(b) { $0["endCursor"] = NSNull() }, batch: b, deviceId: "strap-1"))
        XCTAssertFalse(PushAck.matches(ack(b) { $0["deviceId"] = "other" }, batch: b, deviceId: "strap-1"))
        XCTAssertFalse(PushAck.matches(Data("not json".utf8), batch: b, deviceId: "strap-1"))
        XCTAssertFalse(PushAck.matches(ack(b) { $0.removeValue(forKey: "stream") }, batch: b, deviceId: "strap-1"))
    }

    func testReplaceWindowAckHasNullCursor() throws {
        let rec = MutableRecord(key: [("day", .string("2026-11-17"))], data: Registry.spec("dailyMetric")!.dataColumns.map { ($0, JSONValue.null) })
        let b = try BatchEncoder.replaceWindowBatches(stream: "dailyMetric", sourceId: source, deviceId: "strap-1",
                                                      window: .day(from: "2026-11-05", toInclusive: "2026-11-18"), records: [rec])[0]
        let d: [String: Any] = ["protocolVersion": "1.0", "batchId": b.batchId, "stream": "dailyMetric", "deviceId": "strap-1",
                                "endCursor": NSNull(), "acceptedRows": 1, "status": "accepted"]
        XCTAssertTrue(PushAck.matches(try JSONSerialization.data(withJSONObject: d), batch: b, deviceId: "strap-1"))
    }

    func testCapabilitiesFailClosed() throws {
        let good = #"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":["hrSample","dailyMetric"]}"#
        let caps = try PushCapabilities.parse(Data(good.utf8))
        XCTAssertEqual(caps.streams, ["hrSample", "dailyMetric"])
        XCTAssertEqual(caps.receiverStateId, "5fc7b9a0-8055-4e49-a308-3a290f98d81a")
        XCTAssertThrowsError(try PushCapabilities.parse(Data(#"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":["hrSample","hrSample"]}"#.utf8)))
        XCTAssertThrowsError(try PushCapabilities.parse(Data(#"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":["ppg"]}"#.utf8)))
        XCTAssertThrowsError(try PushCapabilities.parse(Data(#"{"type":"capabilities","protocolVersion":"2.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":[]}"#.utf8)))
        XCTAssertThrowsError(try PushCapabilities.parse(Data(#"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"NOT-A-UUID","streams":[]}"#.utf8)))
        XCTAssertThrowsError(try PushCapabilities.parse(Data(repeating: 0x20, count: 17 * 1024)))
        XCTAssertEqual(try PushCapabilities.parse(Data(#"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":[]}"#.utf8)).streams, [])
    }
}
