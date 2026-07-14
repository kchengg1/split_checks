import XCTest
@testable import SplitChecksCore

final class SplitEngineTests: XCTestCase {

    // Shared fixture: the three-person dinner from PLAN.md.
    // Subtotal 6925, tax 614, 20% tip 1385, grand total 8924.
    private let alice = Person(name: "Alice", colorIndex: 0)
    private let bob = Person(name: "Bob", colorIndex: 1)
    private let cara = Person(name: "Cara", colorIndex: 2)

    private let burger = LineItem(name: "Burger", priceCents: 1450)
    private let pasta = LineItem(name: "Pasta", priceCents: 1725)
    private let salmon = LineItem(name: "Salmon", priceCents: 2200)
    private let fries = LineItem(name: "Fries", priceCents: 650)
    private let tiramisu = LineItem(name: "Tiramisu", priceCents: 900)

    private func dinnerInput(tipRule: AllocationRule = .proportional) -> SplitInput {
        SplitInput(
            items: [burger, pasta, salmon, fries, tiramisu],
            people: [alice, bob, cara],
            assignments: [
                Assignment(itemID: burger.id, personID: alice.id),
                Assignment(itemID: pasta.id, personID: bob.id),
                Assignment(itemID: salmon.id, personID: cara.id),
                Assignment(itemID: fries.id, personID: alice.id),
                Assignment(itemID: fries.id, personID: bob.id),
                Assignment(itemID: tiramisu.id, personID: alice.id),
                Assignment(itemID: tiramisu.id, personID: bob.id),
                Assignment(itemID: tiramisu.id, personID: cara.id),
            ],
            taxCents: 614,
            tipCents: 1385,
            tipRule: tipRule
        )
    }

    func testDinnerScenarioProportional() {
        let result = SplitEngine.split(dinnerInput())

        XCTAssertTrue(result.isFullyAssigned)
        XCTAssertEqual(result.subtotalCents, 6925)
        XCTAssertEqual(result.assignedSubtotalCents, 6925)
        XCTAssertEqual(result.grandTotalCents, 8924)

        // Values verified against the reference implementation.
        XCTAssertEqual(result.shares[0].itemsCents, 2075) // burger + half fries + third tiramisu
        XCTAssertEqual(result.shares[0].taxCents, 184)
        XCTAssertEqual(result.shares[0].tipCents, 415)
        XCTAssertEqual(result.shares[0].totalCents, 2674)

        XCTAssertEqual(result.shares[1].itemsCents, 2350)
        XCTAssertEqual(result.shares[1].taxCents, 208)
        XCTAssertEqual(result.shares[1].tipCents, 470)
        XCTAssertEqual(result.shares[1].totalCents, 3028)

        XCTAssertEqual(result.shares[2].itemsCents, 2500)
        XCTAssertEqual(result.shares[2].taxCents, 222)
        XCTAssertEqual(result.shares[2].tipCents, 500)
        XCTAssertEqual(result.shares[2].totalCents, 3222)

        // The cardinal rule: per-person totals sum exactly to the bill.
        XCTAssertEqual(result.shares.reduce(0) { $0 + $1.totalCents }, result.grandTotalCents)
    }

    func testDinnerScenarioEvenTip() {
        let result = SplitEngine.split(dinnerInput(tipRule: .even))

        XCTAssertEqual(result.shares.map(\.tipCents), [462, 462, 461])
        XCTAssertEqual(result.shares.map(\.totalCents), [2721, 3020, 3183])
        XCTAssertEqual(result.shares.reduce(0) { $0 + $1.totalCents }, result.grandTotalCents)
    }

    func testItemBreakdownShowsTheMath() {
        let result = SplitEngine.split(dinnerInput())

        XCTAssertEqual(result.itemBreakdown[fries.id], [alice.id: 325, bob.id: 325])
        XCTAssertEqual(result.itemBreakdown[tiramisu.id], [alice.id: 300, bob.id: 300, cara.id: 300])
        XCTAssertEqual(result.itemBreakdown[burger.id], [alice.id: 1450])
    }

    func testUnassignedItemsAreReportedAndExcluded() {
        var input = dinnerInput()
        input.assignments.removeAll { $0.itemID == salmon.id }
        let result = SplitEngine.split(input)

        XCTAssertFalse(result.isFullyAssigned)
        XCTAssertEqual(result.unassignedItemIDs, [salmon.id])
        XCTAssertEqual(result.subtotalCents, 6925)
        XCTAssertEqual(result.assignedSubtotalCents, 6925 - 2200)
        // Cara still owes for her tiramisu share.
        XCTAssertEqual(result.shares[2].itemsCents, 300)
    }

    func testUnevenWeightsAndSharedDiscount() {
        // Pizza $25.50 split 2:1, a -$5.00 promo shared evenly, tax + tip.
        let ana = Person(name: "Ana")
        let ben = Person(name: "Ben")
        let pizza = LineItem(name: "Pizza", priceCents: 2550)
        let promo = LineItem(name: "Promo", priceCents: -500)

        let result = SplitEngine.split(SplitInput(
            items: [pizza, promo],
            people: [ana, ben],
            assignments: [
                Assignment(itemID: pizza.id, personID: ana.id, shareWeight: 2),
                Assignment(itemID: pizza.id, personID: ben.id, shareWeight: 1),
                Assignment(itemID: promo.id, personID: ana.id),
                Assignment(itemID: promo.id, personID: ben.id),
            ],
            taxCents: 169,
            tipCents: 410
        ))

        XCTAssertEqual(result.shares[0].itemsCents, 1450) // 1700 pizza - 250 promo
        XCTAssertEqual(result.shares[1].itemsCents, 600)  //  850 pizza - 250 promo
        XCTAssertEqual(result.shares.map(\.totalCents), [1860, 769])
        XCTAssertEqual(result.shares.reduce(0) { $0 + $1.totalCents }, result.grandTotalCents)
    }

    func testPersonWithNoItems() {
        let ana = Person(name: "Ana")
        let ben = Person(name: "Ben")
        let item = LineItem(name: "Salad", priceCents: 1000)
        let assignments = [Assignment(itemID: item.id, personID: ana.id)]

        // Proportional: freeloader owes nothing.
        let proportional = SplitEngine.split(SplitInput(
            items: [item], people: [ana, ben], assignments: assignments, tipCents: 1000
        ))
        XCTAssertEqual(proportional.shares.map(\.totalCents), [2000, 0])

        // Even: tip is shared by everyone at the table.
        let even = SplitEngine.split(SplitInput(
            items: [item], people: [ana, ben], assignments: assignments,
            tipCents: 1000, tipRule: .even
        ))
        XCTAssertEqual(even.shares.map(\.totalCents), [1500, 500])
    }

    func testAssignmentsForUnknownPeopleOrZeroWeightAreIgnored() {
        let ana = Person(name: "Ana")
        let ghost = Person(name: "Ghost") // not on the bill
        let item = LineItem(name: "Soup", priceCents: 700)

        let result = SplitEngine.split(SplitInput(
            items: [item],
            people: [ana],
            assignments: [
                Assignment(itemID: item.id, personID: ghost.id),
                Assignment(itemID: item.id, personID: ana.id, shareWeight: 0),
                Assignment(itemID: item.id, personID: ana.id),
            ]
        ))
        XCTAssertEqual(result.shares[0].itemsCents, 700)
        XCTAssertTrue(result.isFullyAssigned)
    }

    func testEmptyBillProducesZeroes() {
        let ana = Person(name: "Ana")
        let result = SplitEngine.split(SplitInput(items: [], people: [ana], assignments: []))
        XCTAssertEqual(result.shares.map(\.totalCents), [0])
        XCTAssertEqual(result.grandTotalCents, 0)
        XCTAssertTrue(result.isFullyAssigned)
    }
}
