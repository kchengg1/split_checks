import XCTest
@testable import SplitChecksCore

/// Fixture receipts for the parser. Expected values are cross-checked
/// against an independent reference implementation of the same heuristics.
final class ReceiptParserTests: XCTestCase {

    /// Builds observations laid out like a receipt: one entry per visual row,
    /// either a full-width line or a (name, price) column pair.
    private func observations(_ rows: [Row], confidence: Double = 0.95) -> [TextObservation] {
        var result: [TextObservation] = []
        for (index, row) in rows.enumerated() {
            let y = 0.95 - 0.04 * Double(index)
            switch row {
            case .line(let text):
                result.append(TextObservation(text: text, confidence: confidence,
                                              x: 0.05, y: y, width: 0.90, height: 0.03))
            case .columns(let left, let right):
                result.append(TextObservation(text: left, confidence: confidence,
                                              x: 0.05, y: y, width: 0.40, height: 0.03))
                result.append(TextObservation(text: right, confidence: confidence,
                                              x: 0.70, y: y, width: 0.20, height: 0.03))
            }
        }
        return result
    }

    private enum Row {
        case line(String)
        case columns(String, String)
    }

    func testClassicDinerReceipt() {
        let receipt = ReceiptParser.parse(observations([
            .line("JOE'S DINER"),
            .line("123 MAIN ST"),
            .line("CHECK #42"),
            .line("CHEESEBURGER 12.50"),
            .line("2 X COKE 5.00"),
            .line("FRIES 4.25"),
            .line("SUB TOTAL 21.75"),
            .line("SALES TAX 1.93"),
            .line("TOTAL 23.68"),
            .line("VISA 23.68"),
            .line("CHANGE 0.00"),
        ]))

        XCTAssertEqual(receipt.merchantName, "JOE'S DINER")
        XCTAssertEqual(receipt.items.map(\.name), ["CHEESEBURGER", "COKE", "FRIES"])
        XCTAssertEqual(receipt.items.map(\.quantity), [1, 2, 1])
        XCTAssertEqual(receipt.items.map(\.priceCents), [1250, 500, 425])
        XCTAssertEqual(receipt.subtotalCents, 2175)
        XCTAssertEqual(receipt.taxCents, 193)
        XCTAssertNil(receipt.tipCents)
        XCTAssertEqual(receipt.totalCents, 2368)
        XCTAssertEqual(receipt.itemsSubtotalCents, 2175)
        XCTAssertEqual(receipt.subtotalMatchesItems, true)
    }

    func testTwoColumnReceiptWithDiscountModifierAndTaxCode() {
        let receipt = ReceiptParser.parse(observations([
            .line("TRATTORIA ROMA"),
            .columns("MARGHERITA", "14.00 T"),   // trailing tax code
            .line("NO BASIL"),                   // modifier, no price → skipped
            .columns("2 X ESPRESSO", "6.00"),
            .line("2 @ 3.00"),                   // unit-price detail → skipped
            .columns("12 WINGS", "11.99"),       // "12" is part of the name
            .columns("HAPPY HOUR", "(3.00)"),    // discount
            .columns("SUBTOTAL", "28.99"),
            .columns("TAX 8.875%", "2.57"),
            .columns("GRATUITY 18%", "5.22"),
            .columns("TOTAL", "36.78"),
        ]))

        XCTAssertEqual(receipt.merchantName, "TRATTORIA ROMA")
        XCTAssertEqual(receipt.items.map(\.name), ["MARGHERITA", "ESPRESSO", "12 WINGS", "HAPPY HOUR"])
        XCTAssertEqual(receipt.items.map(\.quantity), [1, 2, 1, 1])
        XCTAssertEqual(receipt.items.map(\.priceCents), [1400, 600, 1199, -300])
        XCTAssertEqual(receipt.subtotalCents, 2899)
        XCTAssertEqual(receipt.taxCents, 257)
        XCTAssertEqual(receipt.tipCents, 522)
        XCTAssertEqual(receipt.totalCents, 3678)
        XCTAssertEqual(receipt.subtotalMatchesItems, true)
    }

    func testDishNamesThatLookLikeKeywordsAndSummedTaxes() {
        let receipt = ReceiptParser.parse(observations([
            .line("THE GRILL"),
            .columns("STEAK TIPS", "18.00"),     // a dish, not a tip
            .columns("2X LEMONADE", "7.00"),     // merged quantity token
            .columns("GST", "0.90"),             // two tax lines sum
            .columns("PST", "1.26"),
            .columns("TOTAL", "27.16"),
            .columns("TOTAL TENDERED", "30.00"), // payment, must not clobber total
            .columns("CHANGE DUE", "2.84"),
        ]))

        XCTAssertEqual(receipt.merchantName, "THE GRILL")
        XCTAssertEqual(receipt.items.map(\.name), ["STEAK TIPS", "LEMONADE"])
        XCTAssertEqual(receipt.items.map(\.quantity), [1, 2])
        XCTAssertEqual(receipt.items.map(\.priceCents), [1800, 700])
        XCTAssertNil(receipt.subtotalCents)
        XCTAssertEqual(receipt.taxCents, 216)
        XCTAssertNil(receipt.tipCents)
        XCTAssertEqual(receipt.totalCents, 2716)
        XCTAssertNil(receipt.subtotalMatchesItems)
    }

    func testSubtotalMismatchIsSurfacedNotHidden() {
        let receipt = ReceiptParser.parse(observations([
            .line("CAFE"),
            .line("LATTE 5.00"),
            .line("SUBTOTAL 6.00"), // OCR missed an item
            .line("TOTAL 6.50"),
        ]))
        XCTAssertEqual(receipt.subtotalMatchesItems, false)
        XCTAssertEqual(receipt.itemsSubtotalCents, 500)
        XCTAssertEqual(receipt.subtotalCents, 600)
    }

    func testLowConfidenceRowsCarryTheirConfidence() {
        let shaky = TextObservation(text: "MYSTERY DISH 9.99", confidence: 0.4,
                                    x: 0.05, y: 0.5, width: 0.9, height: 0.03)
        let receipt = ReceiptParser.parse([shaky])
        XCTAssertEqual(receipt.items.first?.ocrConfidence, 0.4)
    }

    func testRowClusteringJoinsColumnsAndOrdersTopToBottom() {
        let name = TextObservation(text: "PASTA", confidence: 1, x: 0.05, y: 0.80, width: 0.3, height: 0.03)
        let price = TextObservation(text: "17.25", confidence: 1, x: 0.70, y: 0.805, width: 0.2, height: 0.03)
        let below = TextObservation(text: "TOTAL 17.25", confidence: 1, x: 0.05, y: 0.60, width: 0.9, height: 0.03)

        let rows = ReceiptParser.clusterRows([below, price, name])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.text), ["PASTA", "17.25"])
        XCTAssertEqual(rows[1].map(\.text), ["TOTAL 17.25"])

        let receipt = ReceiptParser.parse([below, price, name])
        XCTAssertEqual(receipt.items.map(\.priceCents), [1725])
        XCTAssertEqual(receipt.totalCents, 1725)
    }

    func testMoneyTokenParsing() {
        // Table verified against the reference implementation.
        let cases: [(String, Int?)] = [
            ("14.50", 1450), ("$14.50", 1450), ("4,25", 425), ("(3.00)", -300),
            ("-5.00", -500), ("1,234.56", 123456), ("0.00", 0), ("5.00-", -500),
            ("14", nil), ("8.875%", nil), ("ABC", nil), ("14.5", nil), ("", nil),
        ]
        for (token, expected) in cases {
            XCTAssertEqual(ReceiptParser.parseMoneyToken(token), expected, "token: \(token)")
        }
    }

    func testEmptyInput() {
        let receipt = ReceiptParser.parse([])
        XCTAssertTrue(receipt.items.isEmpty)
        XCTAssertNil(receipt.merchantName)
        XCTAssertNil(receipt.subtotalMatchesItems)
    }
}
