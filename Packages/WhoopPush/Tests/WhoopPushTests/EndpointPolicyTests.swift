import Foundation
import XCTest
@testable import WhoopPush

final class EndpointPolicyTests: XCTestCase {
    private func ok(_ s: String) -> String? { try? EndpointPolicy.validate(s).absoluteString }
    private func bad(_ s: String) -> Bool { (try? EndpointPolicy.validate(s)) == nil }

    func testHttpsAnywhere() {
        XCTAssertEqual(ok("https://fitness.askela.cz/push"), "https://fitness.askela.cz/push")
        XCTAssertEqual(ok("https://fitness.askela.cz"), "https://fitness.askela.cz/")
        XCTAssertEqual(ok("https://fitness.askela.cz:443/push"), "https://fitness.askela.cz/push")
        XCTAssertEqual(ok("https://x.cz/push?k=1"), "https://x.cz/push?k=1")
    }

    func testCleartextOnlyForNumericPrivateAddresses() {
        XCTAssertEqual(ok("http://192.168.1.10:8787/push"), "http://192.168.1.10:8787/push")
        XCTAssertEqual(ok("http://10.0.0.5/push"), "http://10.0.0.5/push")
        XCTAssertEqual(ok("http://172.16.4.2/push"), "http://172.16.4.2/push")
        XCTAssertEqual(ok("http://127.0.0.1:8787/push"), "http://127.0.0.1:8787/push")
        XCTAssertEqual(ok("http://169.254.1.1/push"), "http://169.254.1.1/push")
        XCTAssertNotNil(ok("http://[::1]:8787/push"))
        XCTAssertNotNil(ok("http://[fd12:3456::1]/push"))
        XCTAssertTrue(bad("http://8.8.8.8/push"))
        XCTAssertTrue(bad("http://172.32.0.1/push"))
        XCTAssertTrue(bad("http://server.local/push"))
        XCTAssertTrue(bad("http://fitness.askela.cz/push"))
        XCTAssertTrue(bad("http://localhost:8787/push"))
    }

    func testRejectsUserinfoFragmentAndOtherSchemes() {
        XCTAssertTrue(bad("https://user:pw@x.cz/push"))
        XCTAssertTrue(bad("https://x.cz/push#frag"))
        XCTAssertTrue(bad("ftp://x.cz/push"))
        XCTAssertTrue(bad("not a url"))
        XCTAssertTrue(bad("https:///push"))
        XCTAssertTrue(bad(""))
    }
}
