import Foundation
import XCTest
@testable import WhoopPush

/// Očekávané výstupy `java.lang.Double.toString`, které používá Android při kanonizaci čísel.
final class JavaDoubleTests: XCTestCase {
    func testPlainRange() {
        XCTAssertEqual(JavaDouble.string(100.0), "100.0")
        XCTAssertEqual(JavaDouble.string(0.5), "0.5")
        XCTAssertEqual(JavaDouble.string(1.0), "1.0")
        XCTAssertEqual(JavaDouble.string(61.25), "61.25")
        XCTAssertEqual(JavaDouble.string(1234567.0), "1234567.0")
        XCTAssertEqual(JavaDouble.string(0.001), "0.001")
        XCTAssertEqual(JavaDouble.string(-3.5), "-3.5")
    }

    func testScientificRange() {
        XCTAssertEqual(JavaDouble.string(1.0e-4), "1.0E-4")
        XCTAssertEqual(JavaDouble.string(0.00012345), "1.2345E-4")
        XCTAssertEqual(JavaDouble.string(1.0e10), "1.0E10")
        XCTAssertEqual(JavaDouble.string(12345678.0), "1.2345678E7")
        XCTAssertEqual(JavaDouble.string(1.0e7), "1.0E7")
        XCTAssertEqual(JavaDouble.string(-2.5e-10), "-2.5E-10")
    }

    func testZeros() {
        XCTAssertEqual(JavaDouble.string(0.0), "0.0")
        XCTAssertEqual(JavaDouble.string(-0.0), "-0.0")
    }

    func testNonFiniteThrows() {
        XCTAssertThrowsError(try JavaDouble.checked(.infinity))
        XCTAssertThrowsError(try JavaDouble.checked(.nan))
    }
}
