import XCTest
@testable import SplitChecksCore

final class BillSnapshotTests: XCTestCase {

    private func makeSnapshot() -> BillSnapshot {
        let ana = Person(name: "Ana")
        let ben = Person(name: "Ben")
        let pizza = LineItem(name: "Pizza", priceCents: 2550)
        let salad = LineItem(name: "Salad", priceCents: 900)
        return BillSnapshot(
            items: [pizza, salad],
            people: [ana, ben],
            assignments: [
                Assignment(itemID: pizza.id, personID: ana.id),
                Assignment(itemID: pizza.id, personID: ben.id),
                Assignment(itemID: salad.id, personID: ben.id),
            ],
            taxCents: 300,
            tipCents: 690
        )
    }

    func testCodableRoundTripPreservesTheSplit() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BillSnapshot.self, from: data)

        let original = snapshot.result
        let restored = decoded.result
        XCTAssertEqual(restored.shares.map(\.totalCents), original.shares.map(\.totalCents))
        XCTAssertEqual(restored.grandTotalCents, original.grandTotalCents)
        XCTAssertEqual(restored.itemBreakdown, original.itemBreakdown)
        XCTAssertEqual(decoded.taxRule, .proportional)
    }

    func testResultIsExactAndDeterministic() {
        let snapshot = makeSnapshot()
        let result = snapshot.result
        XCTAssertEqual(result.grandTotalCents, 2550 + 900 + 300 + 690)
        XCTAssertEqual(result.shares.reduce(0) { $0 + $1.totalCents }, result.grandTotalCents)
        // Recomputing yields the identical split — safe to store inputs only.
        XCTAssertEqual(snapshot.result.shares, result.shares)
    }

    func testSummaryTextListsEveryoneAndTheTotal() {
        let snapshot = makeSnapshot()
        let text = snapshot.summaryText(merchantName: "Luigi's")
        XCTAssertTrue(text.contains("Luigi's"))
        XCTAssertTrue(text.contains("Ana:"))
        XCTAssertTrue(text.contains("Ben:"))
        XCTAssertTrue(text.contains("Pizza"))
        XCTAssertTrue(text.contains("Tip"))
        XCTAssertTrue(text.contains("Total \(Money.format(snapshot.result.grandTotalCents))"))
    }
}
