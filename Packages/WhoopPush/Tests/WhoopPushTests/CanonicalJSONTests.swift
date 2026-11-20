import Foundation
import XCTest
@testable import WhoopPush

final class CanonicalJSONTests: XCTestCase {
    func testSortsObjectKeysRecursively() throws {
        let v = JSONValue.object([("b", .int(1)), ("a", .object([("z", .null), ("y", .bool(true))]))])
        XCTAssertEqual(try CanonicalJSON.string(v, sortKeys: true), #"{"a":{"y":true,"z":null},"b":1}"#)
    }

    func testKeepsGivenOrderWhenNotSorting() throws {
        let v = JSONValue.object([("ts", .int(100)), ("rrMs", .int(900)), ("seq", .int(0))])
        XCTAssertEqual(try CanonicalJSON.string(v, sortKeys: false), #"{"ts":100,"rrMs":900,"seq":0}"#)
    }

    func testNumbersAndArrays() throws {
        let v = JSONValue.array([.int(-7), .double(100.0), .double(1.0e-4), .string("x")])
        XCTAssertEqual(try CanonicalJSON.string(v, sortKeys: true), #"[-7,100.0,1.0E-4,"x"]"#)
    }

    func testStringEscapingMatchesAndroid() throws {
        // Escapuje jen " \ \b \f \n \r \t a řídicí znaky < 0x20 jako \u00xx; ostatní (i nelatinka a DEL) zůstává syrově.
        let s = "a\"b\\c\u{08}\u{0C}\n\r\t\u{01}é\u{7F}"
        XCTAssertEqual(try CanonicalJSON.string(.string(s), sortKeys: true), "\"a\\\"b\\\\c\\b\\f\\n\\r\\t\\u0001é\u{7F}\"")
    }

    func testNonFiniteNumberThrows() {
        XCTAssertThrowsError(try CanonicalJSON.string(.double(.nan), sortKeys: true))
    }
}
