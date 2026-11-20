import Foundation
import XCTest
@testable import WhoopPush

final class PushIdentityTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    func testKeyFingerprintMatchesAndroidOracle() throws {
        // PushCursorTest.kt:80
        let key: [(String, JSONValue)] = [("ts", .int(100)), ("rrMs", .int(900)), ("seq", .int(0))]
        XCTAssertEqual(try PushIdentity.keyFingerprint(stream: "rrInterval", deviceId: "a", key: key),
                       "3e8a1018cb24f2dcabd66750250c479fe981222da25785cfc78a20d84f1217bb")
    }

    func testRecordLineIsSortedAndNewlineTerminated() throws {
        let line = try PushIdentity.recordLine(key: [("ts", .int(100))], data: [("bpm", .int(61))])
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "{\"data\":{\"bpm\":61},\"key\":{\"ts\":100},\"type\":\"record\"}\n")
    }

    func testBatchIdMatchesIndependentReference() throws {
        let identity = JSONValue.object([
            ("delivery", .string("append")), ("deviceId", .string("strap-1")),
            ("endCursor", .object([("keySha256", .string(b)), ("rowId", .int(2))])),
            ("protocolVersion", .string("1.0")), ("recordCount", .int(2)),
            ("sourceId", .string("3a3486dd-5030-4e17-a00d-a781399890f9")),
            ("startCursor", .object([("keySha256", .string(a)), ("rowId", .int(1))])),
            ("stream", .string("hrSample")), ("type", .string("batch")),
        ])
        let lines = [
            try PushIdentity.recordLine(key: [("ts", .int(100))], data: [("bpm", .int(61))]),
            try PushIdentity.recordLine(key: [("ts", .int(101))], data: [("bpm", .int(62))]),
        ]
        XCTAssertEqual(try PushIdentity.stableUUID(identity: identity, lines: lines), "56a4489f-962a-54cb-94bf-cd125a7945aa")
    }

    func testDayHashSortsLinesBytewiseAndEmptyDayIsHashed() throws {
        let l1 = try PushIdentity.recordLine(key: [("ts", .int(101))], data: [("bpm", .int(62))])
        let l0 = try PushIdentity.recordLine(key: [("ts", .int(100))], data: [("bpm", .int(61))])
        XCTAssertEqual(PushIdentity.snapshotHash(stream: "hrSample", lines: [l1, l0]),
                       "063c74018c7cc2f2913b9a7bb4458bdfa4aa35ad8f24b25be840b7f1ba57a163")
        XCTAssertEqual(PushIdentity.snapshotHash(stream: "dailyMetric", lines: []),
                       "c22495269effdf36ecc2275bde000ae46d52d49b2c7f95fa91c2376476d0a3fe")
    }
}
