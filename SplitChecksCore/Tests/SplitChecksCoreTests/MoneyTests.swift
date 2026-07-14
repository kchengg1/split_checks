import XCTest
@testable import SplitChecksCore

final class MoneyTests: XCTestCase {

    func testParseCommonInputs() {
        XCTAssertEqual(Money.parse("14.50"), 1450)
        XCTAssertEqual(Money.parse("$14.50"), 1450)
        XCTAssertEqual(Money.parse("14.5"), 1450)
        XCTAssertEqual(Money.parse("14"), 1400)
        XCTAssertEqual(Money.parse(" 1,234.56 "), 123456)
        XCTAssertEqual(Money.parse("0.99"), 99)
        XCTAssertEqual(Money.parse("-5.00"), -500)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(Money.parse(""))
        XCTAssertNil(Money.parse("abc"))
        XCTAssertNil(Money.parse("$"))
    }

    func testParseRoundsSubCentInput() {
        XCTAssertEqual(Money.parse("14.505"), 1451)
        XCTAssertEqual(Money.parse("14.504"), 1450)
    }

    func testPercentage() {
        // Verified against the reference implementation.
        XCTAssertEqual(Money.percentage(20, of: 6925), 1385)
        XCTAssertEqual(Money.percentage(18, of: 6925), 1247)
        XCTAssertEqual(Money.percentage(25, of: 333), 83)
        XCTAssertEqual(Money.percentage(20, of: 0), 0)
    }
}
