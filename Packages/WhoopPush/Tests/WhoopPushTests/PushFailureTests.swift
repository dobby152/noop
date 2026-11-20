import Foundation
import XCTest
@testable import WhoopPush

final class PushFailureTests: XCTestCase {
    func testRetryableStatuses() {
        for s in [408, 429, 500, 502, 503, 504] { XCTAssertTrue(PushFailure.http(s).retryable, "HTTP \(s)") }
        for s in [400, 401, 403, 404, 409, 413, 422] { XCTAssertFalse(PushFailure.http(s).retryable, "HTTP \(s)") }
    }

    func testTransportRetryableAckAndProtocolTerminal() {
        XCTAssertTrue(PushFailure.transport.retryable)
        XCTAssertFalse(PushFailure.badAcknowledgement.retryable)
        XCTAssertFalse(PushFailure.invalidCapabilities.retryable)
        XCTAssertFalse(PushFailure.encoding.retryable)
    }

    func testSafeCodeNeverContainsFreeText() {
        XCTAssertEqual(PushFailure.http(503).safeCode, "http_503")
        XCTAssertEqual(PushFailure.transport.safeCode, "transport")
        XCTAssertEqual(PushFailure.badAcknowledgement.safeCode, "bad_acknowledgement")
    }
}
