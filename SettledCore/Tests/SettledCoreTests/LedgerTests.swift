import XCTest
@testable import SettledCore

/// The group ledger: payments, soft delete/restore, the activity trail,
/// pairwise vs. simplified settle-up, and decoding of every shipped
/// payload version.
final class LedgerTests: XCTestCase {

    private let alice = Person(name: "Alice", colorIndex: 0)
    private let bob = Person(name: "Bob", colorIndex: 1)
    private let cara = Person(name: "Cara", colorIndex: 2)
    private let day = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func cents(_ balances: [Balance], _ person: Person) -> Int {
        balances.first { $0.personID == person.id }?.cents ?? 0
    }

    private func weekend(simplify: Bool) -> ExpenseGroup {
        var group = ExpenseGroup(name: "Weekend", simplifyDebts: simplify, people: [alice, bob, cara])
        group.apply(.addEntry(.expense(Expense(title: "Dinner", payerID: alice.id, amountCents: 12000,
                                               split: .equally(participantIDs: [alice.id, bob.id, cara.id])))))
        group.apply(.addEntry(.expense(Expense(title: "Hotel", payerID: bob.id, amountCents: 30000,
                                               split: .equally(participantIDs: [alice.id, bob.id, cara.id])))))
        group.apply(.addEntry(.expense(Expense(title: "Taxi", payerID: cara.id, amountCents: 3000,
                                               split: .equally(participantIDs: [alice.id, bob.id, cara.id])))))
        return group
    }

    // MARK: - Payments

    func testRecordedPaymentReducesBalances() {
        var group = ExpenseGroup(name: "Pair", people: [alice, bob])
        group.apply(.addEntry(.expense(Expense(title: "Lunch", payerID: alice.id, amountCents: 10000,
                                               split: .equally(participantIDs: [alice.id, bob.id])))))
        XCTAssertEqual(cents(SettlementEngine.balances(for: group), bob), -5000)

        // Bob pays Alice back part of it.
        group.apply(.addEntry(.payment(Payment(fromID: bob.id, toID: alice.id, cents: 2000, method: .venmo))))
        let after = SettlementEngine.balances(for: group)
        XCTAssertEqual(cents(after, bob), -3000)
        XCTAssertEqual(cents(after, alice), 3000)
        XCTAssertEqual(after.reduce(0) { $0 + $1.cents }, 0)

        // Paying the rest settles them up: no transfers either way.
        group.apply(.addEntry(.payment(Payment(fromID: bob.id, toID: alice.id, cents: 3000))))
        XCTAssertTrue(SettlementEngine.settlement(for: group).transfers.isEmpty)
        group.simplifyDebts = true
        XCTAssertTrue(SettlementEngine.settlement(for: group).transfers.isEmpty)
        // Payments are transfers, not spend.
        XCTAssertEqual(group.totalCents, 10000)
    }

    // MARK: - Pairwise vs. simplified

    func testPairwiseDebtsShowWhoOwesWhomAsIncurred() {
        let group = weekend(simplify: false)
        let settlement = SettlementEngine.settlement(for: group)
        XCTAssertFalse(settlement.isSimplified)
        // Dinner: Bob and Cara each owe Alice 40. Hotel: Alice and Cara each
        // owe Bob 100. Taxi: Alice and Bob each owe Cara 10.
        // Alice↔Bob: Bob owes Alice 40, Alice owes Bob 100 → Alice owes Bob 60.
        // Alice↔Cara: Cara owes Alice 40, Alice owes Cara 10 → Cara owes Alice 30.
        // Bob↔Cara: Cara owes Bob 100, Bob owes Cara 10 → Cara owes Bob 90.
        XCTAssertEqual(settlement.transfers, [
            Transfer(fromID: alice.id, toID: bob.id, cents: 6000),
            Transfer(fromID: cara.id, toID: alice.id, cents: 3000),
            Transfer(fromID: cara.id, toID: bob.id, cents: 9000),
        ])
    }

    func testSimplifiedSettlementUsesFewerTransfers() {
        let group = weekend(simplify: true)
        let settlement = SettlementEngine.settlement(for: group)
        XCTAssertTrue(settlement.isSimplified)
        XCTAssertEqual(settlement.transfers, [
            Transfer(fromID: cara.id, toID: bob.id, cents: 12000),
            Transfer(fromID: alice.id, toID: bob.id, cents: 3000),
        ])
    }

    /// Property: however they're arranged, both transfer lists clear the
    /// same balances — pairwise nets equal the net balances.
    func testPairwiseAndSimplifiedTransfersBothClearBalances() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let people = (0..<Int.random(in: 2...5, using: &rng)).map { Person(name: "P\($0)", colorIndex: $0) }
            var group = ExpenseGroup(name: "Fuzz", people: people)
            let ids = people.map(\.id)
            for i in 0..<Int.random(in: 1...8, using: &rng) {
                let payer = ids.randomElement(using: &rng)!
                let participants = ids.filter { _ in Bool.random(using: &rng) }
                let amount = Int.random(in: 1...50_000, using: &rng)
                group.apply(.addEntry(.expense(Expense(title: "E\(i)", payerID: payer, amountCents: amount,
                                                       split: .equally(participantIDs: participants)))))
                if Bool.random(using: &rng) {
                    let from = ids.randomElement(using: &rng)!
                    let to = ids.randomElement(using: &rng)!
                    if from != to {
                        group.apply(.addEntry(.payment(Payment(fromID: from, toID: to,
                                                               cents: Int.random(in: 1...20_000, using: &rng)))))
                    }
                }
            }
            let balances = SettlementEngine.balances(for: group)
            let expected = Dictionary(uniqueKeysWithValues: balances.map { ($0.personID, $0.cents) })

            let pairwise = SettlementEngine.netOfTransfers(SettlementEngine.pairwiseDebts(for: group), people: ids)
            XCTAssertEqual(pairwise, expected, "pairwise debts must net to the balances")

            let simplified = SettlementEngine.netOfTransfers(SettlementEngine.simplify(balances), people: ids)
            XCTAssertEqual(simplified, expected, "simplified transfers must net to the balances")
            XCTAssertLessThanOrEqual(SettlementEngine.simplify(balances).count, max(0, people.count - 1))
        }
    }

    // MARK: - apply, soft delete, activity

    func testDeleteRestoreAndActivityTrail() {
        var group = weekend(simplify: false)
        XCTAssertEqual(group.activity.map(\.kind), [.entryAdded, .entryAdded, .entryAdded])
        XCTAssertEqual(group.activity.first?.summary, "Added \"Dinner\": \(Money.format(12000)), paid by Alice")

        let hotelID = group.expenses.first { $0.title == "Hotel" }!.id
        XCTAssertTrue(group.apply(.deleteEntry(hotelID), by: alice.id))
        XCTAssertFalse(group.apply(.deleteEntry(hotelID)), "deleting twice is a no-op")
        XCTAssertEqual(group.expenses.count, 2)
        XCTAssertEqual(group.entries.count, 3, "deleted entries stay as tombstones")
        XCTAssertEqual(group.totalCents, 15000)
        XCTAssertEqual(cents(SettlementEngine.balances(for: group), bob), -5000)

        let deletion = group.activity.last!
        XCTAssertEqual(deletion.kind, .entryDeleted)
        XCTAssertEqual(deletion.subjectID, hotelID)
        XCTAssertEqual(deletion.actorID, alice.id)
        XCTAssertEqual(deletion.before?.expense?.title, "Hotel")
        XCTAssertEqual(deletion.summary, "Deleted \"Hotel\"")

        XCTAssertTrue(group.apply(.restoreEntry(hotelID)))
        XCTAssertEqual(group.expenses.count, 3)
        XCTAssertEqual(group.activity.last?.kind, .entryRestored)
        XCTAssertEqual(cents(SettlementEngine.balances(for: group), bob), 15000)
    }

    func testUpdateEntryKeepsIdentityAndRecordsBefore() {
        var group = weekend(simplify: false)
        var dinner = group.expenses[0]
        dinner.amountCents = 15000
        dinner.title = "Big dinner"
        XCTAssertTrue(group.apply(.updateEntry(.expense(dinner)), at: day))
        XCTAssertEqual(group.expenses[0].title, "Big dinner")
        XCTAssertEqual(group.expenses[0].updatedAt, day)
        XCTAssertEqual(group.activity.last?.before?.expense?.title, "Dinner")
        XCTAssertEqual(group.activity.last?.summary, "Edited \"Big dinner\"")

        let ghost = Expense(title: "Ghost", payerID: alice.id, amountCents: 1, split: .equally(participantIDs: []))
        XCTAssertFalse(group.apply(.updateEntry(.expense(ghost))), "unknown entries can't be updated")
    }

    func testMembersAndSettings() {
        var group = ExpenseGroup(name: "Home", kind: .home, people: [alice])
        XCTAssertTrue(group.apply(.addMember(bob)))
        XCTAssertFalse(group.apply(.addMember(bob)), "no duplicate members")
        group.apply(.addEntry(.expense(Expense(title: "Rent", payerID: alice.id, amountCents: 100000,
                                               split: .equally(participantIDs: [alice.id, bob.id])))))
        XCTAssertFalse(group.apply(.removeMember(bob.id)), "referenced members stay")
        XCTAssertTrue(group.apply(.addMember(cara)))
        XCTAssertTrue(group.apply(.removeMember(cara.id)))
        XCTAssertEqual(group.people.map(\.name), ["Alice", "Bob"])

        XCTAssertTrue(group.apply(.rename("  Our place ")))
        XCTAssertEqual(group.name, "Our place")
        XCTAssertFalse(group.apply(.rename("   ")))
        XCTAssertTrue(group.apply(.setSimplifyDebts(true)))
        XCTAssertFalse(group.apply(.setSimplifyDebts(true)))
        XCTAssertTrue(group.apply(.setKind(.couple)))
        XCTAssertEqual(group.activity.map(\.kind), [
            .memberAdded, .entryAdded, .memberAdded, .memberRemoved, .groupRenamed, .settingsChanged, .settingsChanged,
        ])
    }

    // MARK: - Payload versions

    func testVersion2RoundTrip() throws {
        var group = weekend(simplify: false)
        group.apply(.addEntry(.payment(Payment(fromID: cara.id, toID: bob.id, cents: 5000, date: day,
                                               method: .cash, note: "at the airport", createdAt: day))))
        // Fixed timestamps so equality doesn't hinge on Date precision.
        group.createdAt = day
        for i in group.entries.indices { group.entries[i].updatedAt = day }
        group.entries = group.entries.map { entry in
            switch entry {
            case .expense(var e): e.createdAt = day; e.date = day; return .expense(e)
            case .payment(var p): p.createdAt = day; return .payment(p)
            }
        }
        for i in group.activity.indices { group.activity[i].at = day; group.activity[i].before = nil }

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(ExpenseGroup.self, from: data)
        XCTAssertEqual(decoded, group)
        XCTAssertEqual(decoded.schemaVersion, ExpenseGroup.currentSchemaVersion)
        XCTAssertEqual(SettlementEngine.balances(for: decoded), SettlementEngine.balances(for: group))
    }

    /// A trip exactly as the pre-ledger app wrote it: no kind, no
    /// simplify flag, `expenses` instead of `entries`, no timestamps.
    func testVersion1TripPayloadDecodes() throws {
        let a = "11111111-1111-1111-1111-111111111111"
        let b = "22222222-2222-2222-2222-222222222222"
        let json = """
        {
          "id": "AAAAAAAA-0000-0000-0000-000000000000",
          "name": "Lisbon",
          "currencyCode": "EUR",
          "createdAt": 700000000,
          "people": [
            { "id": "\(a)", "name": "Ana", "colorIndex": 0 },
            { "id": "\(b)", "name": "Ben", "colorIndex": 1 }
          ],
          "expenses": [
            {
              "id": "EEEEEEEE-0000-0000-0000-000000000001",
              "title": "Dinner",
              "payerID": "\(a)",
              "amountCents": 5000,
              "date": 700000000,
              "split": { "equally": { "participantIDs": ["\(a)", "\(b)"] } }
            },
            {
              "id": "EEEEEEEE-0000-0000-0000-000000000002",
              "title": "Tram",
              "payerID": "\(b)",
              "amountCents": 900,
              "date": 700000000,
              "split": { "exactCents": { "_0": ["\(a)", 600, "\(b)", 300] } }
            }
          ]
        }
        """
        let group = try JSONDecoder().decode(ExpenseGroup.self, from: Data(json.utf8))

        XCTAssertEqual(group.name, "Lisbon")
        XCTAssertEqual(group.kind, .trip)
        XCTAssertTrue(group.simplifyDebts, "old trips always showed minimized transfers")
        XCTAssertEqual(group.currencyCode, "EUR")
        XCTAssertEqual(group.people.map(\.name), ["Ana", "Ben"])
        XCTAssertTrue(group.people.allSatisfy { $0.handles.isEmpty })
        XCTAssertEqual(group.expenses.map(\.title), ["Dinner", "Tram"])
        XCTAssertTrue(group.activity.isEmpty)
        XCTAssertEqual(group.schemaVersion, ExpenseGroup.currentSchemaVersion)

        let dinner = group.expenses[0]
        XCTAssertFalse(dinner.isDeleted)
        XCTAssertEqual(dinner.createdAt, dinner.date)
        XCTAssertEqual(dinner.updatedAt, dinner.date)

        // Ben owes Ana 2500 for dinner; Ana owes Ben 600 for the tram.
        let balances = SettlementEngine.balances(for: group)
        XCTAssertEqual(balances.map(\.cents), [1900, -1900])

        // Re-encoding upgrades the payload to the current shape.
        let upgraded = try JSONDecoder().decode(ExpenseGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(upgraded, group)
    }
}
