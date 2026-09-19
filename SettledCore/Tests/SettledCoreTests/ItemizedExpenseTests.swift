import XCTest
@testable import SettledCore

/// Milestone 8: a scanned bill becomes a group expense.
final class ItemizedExpenseTests: XCTestCase {

    private let ana = Person(name: "Ana", colorIndex: 0)
    private let ben = Person(name: "Ben", colorIndex: 1)
    private let cy = Person(name: "Cy", colorIndex: 2)

    /// Pizza 25.50 shared by Ana and Ben, salad 9.00 for Ben, tax 3.00,
    /// tip 6.90 (proportional). Grand total 44.40.
    private func snapshot() -> BillSnapshot {
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

    func testItemizedExpenseMatchesTheBillExactly() {
        let bill = snapshot()
        let expense = Expense.itemized(from: bill, title: "Luigi's", payers: [ana.id: 0])
        XCTAssertTrue(expense.isItemized)
        XCTAssertEqual(expense.amountCents, 4440)
        XCTAssertEqual(expense.payers, [ana.id: 4440], "a single payer stretches to the bill total")
        XCTAssertEqual(expense.category, .food)

        let result = bill.result
        guard case .exactCents(let shares) = expense.split else { return XCTFail("expected exact cents") }
        XCTAssertEqual(shares[ana.id], result.shares[0].totalCents)
        XCTAssertEqual(shares[ben.id], result.shares[1].totalCents)
        XCTAssertEqual(shares.values.reduce(0, +), 4440)

        // In a group with both people, it validates and balances exactly.
        var group = ExpenseGroup(name: "Dinner", people: [ana, ben])
        XCTAssertTrue(ExpenseValidator.validate(expense, in: group).isEmpty)
        group.apply(.addEntry(.expense(expense)))
        let balances = SettlementEngine.balances(for: group)
        XCTAssertEqual(balances.map(\.cents), [result.shares[1].totalCents, -result.shares[1].totalCents])
    }

    func testMappingSendsBillPeopleToMembersAndMergesShares() {
        let bill = snapshot()
        // Ana on the bill is Cy in the group; Ben on the bill is also Cy
        // (someone entered them twice) — their shares combine.
        let expense = Expense.itemized(from: bill, title: "Luigi's", payers: [cy.id: 0],
                                       mapping: [ana.id: cy.id, ben.id: cy.id])
        guard case .exactCents(let shares) = expense.split else { return XCTFail("expected exact cents") }
        XCTAssertEqual(shares, [cy.id: 4440])
        XCTAssertEqual(expense.payers, [cy.id: 4440])
    }

    func testReapplyingAnEditedBillKeepsIdentityAndPayerCoverage() {
        var expense = Expense.itemized(from: snapshot(), title: "Luigi's", payers: [ana.id: 0], notes: "birthday")
        let id = expense.id
        let created = expense.createdAt

        var edited = snapshot()
        edited.tipCents = 1000   // tip changed on review
        expense.applyItemizedBill(edited)

        XCTAssertEqual(expense.id, id)
        XCTAssertEqual(expense.createdAt, created)
        XCTAssertEqual(expense.notes, "birthday")
        XCTAssertEqual(expense.amountCents, 4750)
        XCTAssertEqual(expense.payers, [ana.id: 4750])
        XCTAssertEqual(expense.itemizedBill, edited)

        // Several payers are not silently rescaled; the validator says so.
        expense.payers = [ana.id: 2000, ben.id: 2440]
        expense.applyItemizedBill(snapshot())
        XCTAssertEqual(expense.amountCents, 4440)
        XCTAssertEqual(expense.payers, [ana.id: 2000, ben.id: 2440])
        XCTAssertTrue(ExpenseValidator.validate(expense, in: ExpenseGroup(name: "G", people: [ana, ben])).isEmpty)
        expense.payers = [ana.id: 1000, ben.id: 1000]
        XCTAssertEqual(ExpenseValidator.validate(expense, in: ExpenseGroup(name: "G", people: [ana, ben])),
                       [.payersDoNotSumToAmount(differenceCents: 2440)])
    }

    func testItemizedExpenseRoundTripsThroughTheGroupPayload() throws {
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var group = ExpenseGroup(name: "Dinner", people: [ana, ben], createdAt: day)
        let expense = Expense.itemized(from: snapshot(), title: "Luigi's", payers: [ana.id: 0], date: day)
        group.apply(.addEntry(.expense(expense)), at: day)
        for i in group.entries.indices { group.entries[i].updatedAt = day }
        group.entries = group.entries.map { entry in
            guard case .expense(var e) = entry else { return entry }
            e.createdAt = day
            return .expense(e)
        }
        for i in group.activity.indices { group.activity[i].at = day }

        let decoded = try JSONDecoder().decode(ExpenseGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(decoded, group)
        XCTAssertEqual(decoded.expenses[0].itemizedBill?.items.map(\.name), ["Pizza", "Salad"])
        XCTAssertEqual(decoded.expenses[0].itemizedBill?.result.grandTotalCents, 4440)
    }
}
