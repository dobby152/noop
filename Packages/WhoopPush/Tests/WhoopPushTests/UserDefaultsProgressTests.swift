import Foundation
import XCTest
@testable import WhoopPush

final class UserDefaultsProgressTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "whooppush-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testCursorRoundTripAndClear() {
        let p = UserDefaultsPushProgress(defaults: makeDefaults(), namespace: "ns1")
        XCTAssertNil(p.cursor(stream: "hrSample", deviceId: "d"))
        let c = Cursor(rowId: 42, keySha256: String(repeating: "a", count: 64))
        p.setCursor(c, stream: "hrSample", deviceId: "d")
        XCTAssertEqual(p.cursor(stream: "hrSample", deviceId: "d"), c)
        p.setCursor(nil, stream: "hrSample", deviceId: "d")
        XCTAssertNil(p.cursor(stream: "hrSample", deviceId: "d"))
    }

    func testDayHashesRoundTrip() {
        let p = UserDefaultsPushProgress(defaults: makeDefaults(), namespace: "ns1")
        XCTAssertEqual(p.dayHashes(stream: "dailyMetric", deviceId: "d"), [:])
        p.setDayHashes(["2026-11-17": "abc", "2026-11-18": "def"], stream: "dailyMetric", deviceId: "d")
        XCTAssertEqual(p.dayHashes(stream: "dailyMetric", deviceId: "d"), ["2026-11-17": "abc", "2026-11-18": "def"])
    }

    func testStreamsDevicesAndNamespacesAreIsolated() {
        let d = makeDefaults()
        let a = UserDefaultsPushProgress(defaults: d, namespace: "ns1")
        let b = UserDefaultsPushProgress(defaults: d, namespace: "ns2")
        let c = Cursor(rowId: 1, keySha256: String(repeating: "b", count: 64))
        a.setCursor(c, stream: "hrSample", deviceId: "d1")
        XCTAssertNil(a.cursor(stream: "hrSample", deviceId: "d2"))
        XCTAssertNil(a.cursor(stream: "rrInterval", deviceId: "d1"))
        XCTAssertNil(b.cursor(stream: "hrSample", deviceId: "d1"))
    }

    func testCorruptStoredValueIsTreatedAsMissing() {
        let d = makeDefaults()
        let p = UserDefaultsPushProgress(defaults: d, namespace: "ns1")
        p.setCursor(Cursor(rowId: 1, keySha256: String(repeating: "c", count: 64)), stream: "hrSample", deviceId: "d")
        for key in d.dictionaryRepresentation().keys where key.contains("cursor") { d.set("garbage", forKey: key) }
        XCTAssertNil(p.cursor(stream: "hrSample", deviceId: "d"))
    }

    func testNamespaceIsDerivedFromDestinationButNotFromTheToken() {
        let a = PushNamespace.make(sourceId: "s", endpoint: "https://x.cz/push", version: "1.0", receiverStateId: "r1")
        XCTAssertEqual(a, PushNamespace.make(sourceId: "s", endpoint: "https://x.cz/push", version: "1.0", receiverStateId: "r1"))
        XCTAssertEqual(a.count, 24)
        XCTAssertTrue(a != PushNamespace.make(sourceId: "s", endpoint: "https://y.cz/push", version: "1.0", receiverStateId: "r1"))
        XCTAssertTrue(a != PushNamespace.make(sourceId: "s", endpoint: "https://x.cz/push", version: "1.0", receiverStateId: "r2"))
        XCTAssertTrue(a != PushNamespace.make(sourceId: "s2", endpoint: "https://x.cz/push", version: "1.0", receiverStateId: "r1"))
    }
}
