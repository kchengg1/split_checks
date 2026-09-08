import XCTest
@testable import SplitChecksCore

/// Trip balance and settle-up tests. Expected values are cross-checked
/// against an independent reference implementation of the same algorithm.
final class SettlementEngineTests: XCTestCase {

    private let alice = Person(name: "Alice", colorIndex: 0)
    private let bob = Person(name: "Bob", colorIndex: 1)
    private let cara = Person(name: "Cara", colorIndex: 2)

    private func cents(_ balances: [Balance], _ person: Person) -> Int {
        balances.first { $0.personID == person.id }?.cents ?? 0
    }

    func testTripScenarioBalancesAndSettlement() {
        let trip = Trip(
            name: "Weekend",
            people: [alice, bob, cara],
            expenses: [
                Expense(title: "Dinner", payerID: alice.id, amountCents: 12000,
                        split: .equally(participantIDs: [alice.id, bob.id, cara.id])),
                Expense(title: "Hotel", payerID: bob.id, amountCents: 30000,
                        split: .equally(participantIDs: [alice.id, bob.id, cara.id])),
                Expense(title: "Taxi", payerID: cara.id, amountCents: 3000,
                        split: .equally(participantIDs: [alice.id, bob.id, cara.id])),
                Expense(title: "Museum", payerID: alice.id, amountCents: 5000,
                        split: .equally(participantIDs: [alice.id, bob.id])),
            ]
        )

        let settlement = SettlementEngine.settlement(for: trip)

        // Net balances verified against the reference implementation.
        XCTAssertEqual(cents(settlement.balances, alice), -500)
        XCTAssertEqual(cents(settlement.balances, bob), 12500)
        XCTAssertEqual(cents(settlement.balances, cara), -12000)
        // Balances always sum to zero — money is conserved.
        XCTAssertEqual(settlement.balances.reduce(0) { $0 + $1.cents }, 0)

        // Minimized settle-up: Cara pays Bob 120.00, Alice pays Bob 5.00.
        XCTAssertEqual(settlement.transfers, [
            Transfer(fromID: cara.id, toID: bob.id, cents: 12000),
            Transfer(fromID: alice.id, toID: bob.id, cents: 500),
        ])
    }

    func testSettlingTransfersClearsAllBalances() {
        // Property: applying the transfers zeroes everyone out.
        let trip = Trip(
            name: "Road trip",
            people: [alice, bob, cara],
            expenses: [
                Expense(title: "Gas", payerID: alice.id, amountCents: 8137,
                        split: .equally(participantIDs: [alice.id, bob.id, cara.id])),
                Expense(title: "Cabin", payerID: cara.id, amountCents: 41999,
                        split: .equally(participantIDs: [alice.id, bob.id, cara.id])),
                Expense(title: "Snacks", payerID: bob.id, amountCents: 1234,
                        split: .shares([alice.id: 1, bob.id: 3])),
            ]
        )
        let settlement = SettlementEngine.settlement(for: trip)
        XCTAssertEqual(settlement.balances.reduce(0) { $0 + $1.cents }, 0)

        var settled = Dictionary(uniqueKeysWithValues: settlement.balances.map { ($0.personID, $0.cents) })
        for transfer in settlement.transfers {
            settled[transfer.fromID, default: 0] += transfer.cents
            settled[transfer.toID, default: 0] -= transfer.cents
        }
        XCTAssertTrue(settled.values.allSatisfy { $0 == 0 })
        XCTAssertLessThanOrEqual(settlement.transfers.count, trip.people.count - 1)
    }

    func testOwedSharesForEachSplitMethod() {
        let known: Set<Person.ID> = [alice.id, bob.id, cara.id]

        let equally = Expense(title: "x", payerID: alice.id, amountCents: 10000,
                              split: .equally(participantIDs: [alice.id, bob.id, cara.id]))
        XCTAssertEqual(SettlementEngine.owedShares(for: equally, knownPeople: known),
                       [alice.id: 3334, bob.id: 3333, cara.id: 3333])

        let shares = Expense(title: "x", payerID: alice.id, amountCents: 9000,
                             split: .shares([alice.id: 2, bob.id: 1]))
        XCTAssertEqual(SettlementEngine.owedShares(for: shares, knownPeople: known),
                       [alice.id: 6000, bob.id: 3000])

        let exact = Expense(title: "x", payerID: alice.id, amountCents: 9000,
                            split: .exactCents([alice.id: 6000, bob.id: 3000]))
        XCTAssertEqual(SettlementEngine.owedShares(for: exact, knownPeople: known),
                       [alice.id: 6000, bob.id: 3000])

        let pct = Expense(title: "x", payerID: alice.id, amountCents: 10001,
                          split: .percentages([alice.id: 6000, bob.id: 4000]))
        XCTAssertEqual(SettlementEngine.owedShares(for: pct, knownPeople: known),
                       [alice.id: 6001, bob.id: 4000])
    }

    func testTwoPayerMinimalSettlement() {
        let trip = Trip(
            name: "Pair",
            people: [alice, bob],
            expenses: [
                Expense(title: "Lunch", payerID: alice.id, amountCents: 10000,
                        split: .equally(participantIDs: [alice.id, bob.id])),
                Expense(title: "Coffee", payerID: bob.id, amountCents: 4000,
                        split: .equally(participantIDs: [alice.id, bob.id])),
            ]
        )
        let settlement = SettlementEngine.settlement(for: trip)
        XCTAssertEqual(cents(settlement.balances, alice), 3000)
        XCTAssertEqual(cents(settlement.balances, bob), -3000)
        XCTAssertEqual(settlement.transfers, [Transfer(fromID: bob.id, toID: alice.id, cents: 3000)])
    }

    func testEmptyAndSinglePersonTrips() {
        let empty = Trip(name: "Empty", people: [alice], expenses: [])
        let s1 = SettlementEngine.settlement(for: empty)
        XCTAssertEqual(cents(s1.balances, alice), 0)
        XCTAssertTrue(s1.transfers.isEmpty)

        // Payer covers an expense nobody is assigned to: they owe it to
        // themselves, so their net stays zero and money is conserved.
        let solo = Trip(name: "Solo", people: [alice],
                        expenses: [Expense(title: "Ticket", payerID: alice.id, amountCents: 2000,
                                           split: .equally(participantIDs: []))])
        let s2 = SettlementEngine.settlement(for: solo)
        XCTAssertEqual(cents(s2.balances, alice), 0)
        XCTAssertTrue(s2.transfers.isEmpty)
    }

    func testTripCodableRoundTrip() throws {
        // Fixed timestamps so JSON round-trip equality doesn't hinge on
        // floating-point precision of `Date`.
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let trip = Trip(
            name: "Codable",
            currencyCode: "EUR",
            people: [alice, bob],
            expenses: [
                Expense(title: "A", payerID: alice.id, amountCents: 1000, date: day,
                        split: .equally(participantIDs: [alice.id, bob.id])),
                Expense(title: "B", payerID: bob.id, amountCents: 2000, date: day,
                        split: .shares([alice.id: 1, bob.id: 2])),
                Expense(title: "C", payerID: alice.id, amountCents: 3000, date: day,
                        split: .percentages([alice.id: 5000, bob.id: 5000])),
                Expense(title: "D", payerID: bob.id, amountCents: 4000, date: day,
                        split: .exactCents([alice.id: 1500, bob.id: 2500])),
            ],
            createdAt: day
        )
        let data = try JSONEncoder().encode(trip)
        let decoded = try JSONDecoder().decode(Trip.self, from: data)

        XCTAssertEqual(decoded, trip)
        XCTAssertEqual(SettlementEngine.balances(for: decoded), SettlementEngine.balances(for: trip))
    }
}
