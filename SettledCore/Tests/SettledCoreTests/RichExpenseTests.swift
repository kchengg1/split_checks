import XCTest
@testable import SettledCore

/// Milestone 7: multiple payers, adjustment splits, per-currency balances,
/// manual conversion, validation, recurring expenses, and decoding of the
/// single-payer (version 2) payload.
final class RichExpenseTests: XCTestCase {

    private let alice = Person(name: "Alice", colorIndex: 0)
    private let bob = Person(name: "Bob", colorIndex: 1)
    private let cara = Person(name: "Cara", colorIndex: 2)
    private var known: Set<Person.ID> { [alice.id, bob.id, cara.id] }

    private func cents(_ balances: [Balance], _ person: Person) -> Int {
        balances.first { $0.personID == person.id }?.cents ?? 0
    }

    // MARK: - Adjustment split

    func testAdjustmentSplitAddsExtrasThenSharesTheRest() {
        // $100: Bob had $10 of extras, Cara a $4 discount; the remaining
        // $94 splits three ways.
        let expense = Expense(title: "Dinner", payerID: alice.id, amountCents: 10000,
                              split: .adjustment(participantIDs: [alice.id, bob.id, cara.id],
                                                 adjustments: [bob.id: 1000, cara.id: -400]))
        let shares = SettlementEngine.owedShares(for: expense, knownPeople: known)
        XCTAssertEqual(shares.values.reduce(0, +), 10000)
        XCTAssertEqual(shares[alice.id], 3134)
        XCTAssertEqual(shares[bob.id], 3133 + 1000)
        XCTAssertEqual(shares[cara.id], 3133 - 400)
    }

    // MARK: - Multiple payers

    func testMultiPayerBalancesAndPairwiseDebts() {
        var group = ExpenseGroup(name: "Cabin", people: [alice, bob, cara])
        // $300 cabin: Alice paid 200, Bob paid 100, split three ways (100 each).
        group.apply(.addEntry(.expense(Expense(title: "Cabin", payers: [alice.id: 20000, bob.id: 10000],
                                               amountCents: 30000,
                                               split: .equally(participantIDs: [alice.id, bob.id, cara.id])))))
        let balances = SettlementEngine.balances(for: group)
        XCTAssertEqual(cents(balances, alice), 10000)
        XCTAssertEqual(cents(balances, bob), 0)
        XCTAssertEqual(cents(balances, cara), -10000)

        // Pairwise: Cara is the only debtor; Alice the only creditor.
        XCTAssertEqual(SettlementEngine.pairwiseDebts(for: group),
                       [Transfer(fromID: cara.id, toID: alice.id, cents: 10000)])

        let expense = group.expenses[0]
        XCTAssertTrue(expense.isMultiPayer)
        XCTAssertEqual(expense.payerID, alice.id, "the main payer is whoever paid most")
        XCTAssertEqual(expense.payerIDs, [alice.id, bob.id])
        XCTAssertEqual(group.activity.first?.summary,
                       "Added \"Cabin\": \(Money.format(30000)), paid by Alice and Bob")
    }

    func testMultiPayerPairwiseMatchesInPeopleOrder() {
        var group = ExpenseGroup(name: "Mixed", people: [alice, bob, cara])
        // Alice paid 90, Bob 30; Bob owes 40, Cara 80, Alice 0.
        group.apply(.addEntry(.expense(Expense(title: "Gear", payers: [alice.id: 9000, bob.id: 3000],
                                               amountCents: 12000,
                                               split: .exactCents([bob.id: 4000, cara.id: 8000])))))
        // Net: Alice +90, Bob -10, Cara -80. In people order, Bob then Cara
        // pay Alice.
        XCTAssertEqual(SettlementEngine.pairwiseDebts(for: group), [
            Transfer(fromID: bob.id, toID: alice.id, cents: 1000),
            Transfer(fromID: cara.id, toID: alice.id, cents: 8000),
        ])
    }

    // MARK: - Currencies

    func testExpensesInAnotherCurrencyGetTheirOwnBalances() {
        var group = ExpenseGroup(name: "Euro trip", currencyCode: "USD", people: [alice, bob])
        group.apply(.addEntry(.expense(Expense(title: "Flights", payerID: alice.id, amountCents: 40000,
                                               split: .equally(participantIDs: [alice.id, bob.id])))))
        group.apply(.addEntry(.expense(Expense(title: "Dinner", payerID: bob.id, amountCents: 6000, currencyCode: "EUR",
                                               split: .equally(participantIDs: [alice.id, bob.id])))))
        group.apply(.addEntry(.payment(Payment(fromID: alice.id, toID: bob.id, cents: 1000, currencyCode: "EUR"))))

        XCTAssertEqual(SettlementEngine.currencies(in: group), ["USD", "EUR"])
        XCTAssertEqual(group.expenses[0].currencyCode, "USD", "empty currency becomes the group's")

        let usd = SettlementEngine.settlement(for: group, currencyCode: "USD")
        XCTAssertEqual(cents(usd.balances, bob), -20000)
        let eur = SettlementEngine.settlement(for: group, currencyCode: "EUR")
        XCTAssertEqual(cents(eur.balances, alice), -2000, "owes 30 for dinner, paid back 10")
        XCTAssertEqual(eur.transfers, [Transfer(fromID: alice.id, toID: bob.id, cents: 2000)])

        let all = SettlementEngine.settlements(for: group)
        XCTAssertEqual(all.map(\.currencyCode), ["USD", "EUR"])
        for settlement in all {
            XCTAssertEqual(settlement.balances.reduce(0) { $0 + $1.cents }, 0)
        }
    }

    func testConversionMovesAnExpenseIntoTheGroupCurrency() {
        var group = ExpenseGroup(name: "Home", currencyCode: "USD", people: [alice, bob, cara])
        // €90 counted as $100, split three ways: converted shares apportion
        // the $100 by the €30/€30/€30 shares.
        group.apply(.addEntry(.expense(Expense(title: "Tapas", payerID: alice.id, amountCents: 9000, currencyCode: "EUR",
                                               split: .equally(participantIDs: [alice.id, bob.id, cara.id]),
                                               conversion: ConvertedAmount(currencyCode: "USD", amountCents: 10000)))))
        XCTAssertEqual(SettlementEngine.currencies(in: group), ["USD"])
        let contribution = SettlementEngine.contribution(for: group.expenses[0], knownPeople: known)
        XCTAssertEqual(contribution.currencyCode, "USD")
        XCTAssertEqual(contribution.paid, [alice.id: 10000])
        XCTAssertEqual(contribution.owed.values.sorted(), [3333, 3333, 3334])
        let balances = SettlementEngine.balances(for: group)
        XCTAssertTrue([6666, 6667].contains(cents(balances, alice)))
        XCTAssertTrue(cents(balances, bob) < 0 && cents(balances, cara) < 0)
        XCTAssertEqual(balances.reduce(0) { $0 + $1.cents }, 0)
        XCTAssertTrue(SettlementEngine.balances(for: group, currencyCode: "EUR").allSatisfy { $0.cents == 0 })
    }

    func testFuzzMultiPayerMultiCurrencyInvariants() {
        var rng = SystemRandomNumberGenerator()
        let codes = ["USD", "EUR", "GBP"]
        for _ in 0..<200 {
            let people = (0..<Int.random(in: 2...5, using: &rng)).map { Person(name: "P\($0)", colorIndex: $0) }
            let ids = people.map(\.id)
            var group = ExpenseGroup(name: "Fuzz", people: people)
            for i in 0..<Int.random(in: 1...8, using: &rng) {
                let amount = Int.random(in: 1...50_000, using: &rng)
                let payerCount = Int.random(in: 1...min(3, ids.count), using: &rng)
                let payerIDs = Array(ids.shuffled(using: &rng).prefix(payerCount))
                let paid = SplitEngine.apportion(amount, weights: payerIDs.map { _ in Int.random(in: 1...5, using: &rng) })
                let participants = ids.filter { _ in Bool.random(using: &rng) }
                let split: SplitMethod = Bool.random(using: &rng)
                    ? .equally(participantIDs: participants)
                    : .adjustment(participantIDs: participants,
                                  adjustments: Dictionary(uniqueKeysWithValues: participants.map { ($0, Int.random(in: -200...200, using: &rng)) }))
                let conversion = Bool.random(using: &rng) ? nil
                    : ConvertedAmount(currencyCode: codes.randomElement(using: &rng)!, amountCents: Int.random(in: 1...60_000, using: &rng))
                group.apply(.addEntry(.expense(Expense(
                    title: "E\(i)", payers: Dictionary(uniqueKeysWithValues: zip(payerIDs, paid)), amountCents: amount,
                    currencyCode: codes.randomElement(using: &rng)!, split: split, conversion: conversion))))
                if Bool.random(using: &rng) {
                    let from = ids.randomElement(using: &rng)!, to = ids.randomElement(using: &rng)!
                    if from != to {
                        group.apply(.addEntry(.payment(Payment(fromID: from, toID: to, cents: Int.random(in: 1...20_000, using: &rng),
                                                               currencyCode: codes.randomElement(using: &rng)!))))
                    }
                }
            }
            for settlement in SettlementEngine.settlements(for: group) {
                let expected = Dictionary(uniqueKeysWithValues: settlement.balances.map { ($0.personID, $0.cents) })
                XCTAssertEqual(settlement.balances.reduce(0) { $0 + $1.cents }, 0, "balances conserve money")
                let pairwise = SettlementEngine.netOfTransfers(
                    SettlementEngine.pairwiseDebts(for: group, currencyCode: settlement.currencyCode), people: ids)
                XCTAssertEqual(pairwise, expected, "pairwise debts net to the balances")
                let simplified = SettlementEngine.netOfTransfers(SettlementEngine.simplify(settlement.balances), people: ids)
                XCTAssertEqual(simplified, expected, "simplified transfers net to the balances")
            }
        }
    }

    // MARK: - Validation

    func testValidatorCatchesEveryMistake() {
        let group = ExpenseGroup(name: "V", people: [alice, bob])
        let stranger = Person(name: "Stranger")

        let good = Expense(title: "OK", payers: [alice.id: 600, bob.id: 400], amountCents: 1000,
                           split: .equally(participantIDs: [alice.id, bob.id]))
        XCTAssertTrue(ExpenseValidator.validate(good, in: group).isEmpty)

        let bad = Expense(title: "  ", payers: [alice.id: 900, stranger.id: 50], amountCents: 0,
                          split: .exactCents([alice.id: 10, stranger.id: 5]))
        let errors = Set(ExpenseValidator.validate(bad, in: group))
        XCTAssertTrue(errors.contains(.emptyTitle))
        XCTAssertTrue(errors.contains(.zeroAmount))
        XCTAssertTrue(errors.contains(.payersDoNotSumToAmount(differenceCents: -950)))
        XCTAssertTrue(errors.contains(.unknownPerson(stranger.id)))
        XCTAssertTrue(errors.contains(.exactSharesDoNotSumToAmount(differenceCents: -15)))

        let overAdjusted = Expense(title: "Over", payerID: alice.id, amountCents: 1000,
                                   split: .adjustment(participantIDs: [alice.id, bob.id], adjustments: [bob.id: 1500]))
        XCTAssertEqual(ExpenseValidator.validate(overAdjusted, in: group), [.adjustmentsExceedAmount(byCents: 500)])

        let noWeights = Expense(title: "W", payerID: alice.id, amountCents: 1000, split: .shares([alice.id: 0]))
        XCTAssertEqual(ExpenseValidator.validate(noWeights, in: group), [.noPositiveWeights])

        let badPercent = Expense(title: "P", payerID: alice.id, amountCents: 1000, split: .percentages([alice.id: 6000, bob.id: 3000]))
        XCTAssertEqual(ExpenseValidator.validate(badPercent, in: group), [.percentagesDoNotSumToWhole(differenceBasisPoints: 1000)])

        let badConversion = Expense(title: "C", payerID: alice.id, amountCents: 1000, currencyCode: "EUR",
                                    split: .equally(participantIDs: [alice.id]),
                                    conversion: ConvertedAmount(currencyCode: "USD", amountCents: 0))
        XCTAssertEqual(ExpenseValidator.validate(badConversion, in: group), [.conversionNotPositive])
    }

    // MARK: - Recurring

    func testRecurringExpensesMaterializeOnceEach() {
        let calendar = Calendar(identifier: .gregorian)
        var group = ExpenseGroup(name: "Home", kind: .home, people: [alice, bob])
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let rent = Expense(title: "Rent", payerID: alice.id, amountCents: 200000, date: start,
                           split: .equally(participantIDs: [alice.id, bob.id]),
                           recurrence: RecurrenceRule(frequency: .monthly,
                                                      nextDate: RecurrenceRule.firstNextDate(after: start, frequency: .monthly, using: calendar)))
        group.apply(.addEntry(.expense(rent)))

        // Mid-March: February and March are due.
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        XCTAssertEqual(group.materializeRecurring(now: now, calendar: calendar), 2)
        XCTAssertEqual(group.expenses.count, 3)
        XCTAssertEqual(group.materializeRecurring(now: now, calendar: calendar), 0, "idempotent")

        let copies = group.expenses.filter { $0.recurringSourceID == rent.id }
        XCTAssertEqual(copies.map { calendar.component(.month, from: $0.date) }, [2, 3])
        XCTAssertTrue(copies.allSatisfy { $0.recurrence == nil && $0.amountCents == 200000 })

        let template = group.expenses.first { $0.id == rent.id }!
        XCTAssertEqual(calendar.component(.month, from: template.recurrence!.nextDate), 4)

        XCTAssertEqual(cents(SettlementEngine.balances(for: group), bob), -300000)
        XCTAssertEqual(group.activity.filter { $0.kind == .entryAdded }.count, 3)
    }

    // MARK: - Settings & payloads

    func testSetCurrency() {
        var group = ExpenseGroup(name: "G", people: [alice])
        XCTAssertTrue(group.apply(.setCurrency("eur")))
        XCTAssertEqual(group.currencyCode, "EUR")
        XCTAssertFalse(group.apply(.setCurrency("EUR")))
        XCTAssertFalse(group.apply(.setCurrency("euros")))
    }

    /// A ledger written by the previous version: single `payerID`, no
    /// currency, category, or notes on the expense.
    func testVersion2LedgerPayloadDecodes() throws {
        let a = "11111111-1111-1111-1111-111111111111"
        let b = "22222222-2222-2222-2222-222222222222"
        let json = """
        {
          "id": "AAAAAAAA-0000-0000-0000-000000000000",
          "name": "Old ledger", "kind": "home", "currencyCode": "GBP", "simplifyDebts": false,
          "createdAt": 700000000, "schemaVersion": 2, "activity": [],
          "people": [
            { "id": "\(a)", "name": "Ana", "colorIndex": 0 },
            { "id": "\(b)", "name": "Ben", "colorIndex": 1 }
          ],
          "entries": [
            { "expense": { "_0": {
              "id": "EEEEEEEE-0000-0000-0000-000000000001", "title": "Groceries", "payerID": "\(a)",
              "amountCents": 5000, "date": 700000000, "isDeleted": false, "createdAt": 700000000, "updatedAt": 700000000,
              "split": { "equally": { "participantIDs": ["\(a)", "\(b)"] } } } } },
            { "payment": { "_0": {
              "id": "EEEEEEEE-0000-0000-0000-000000000002", "fromID": "\(b)", "toID": "\(a)", "cents": 1000,
              "currencyCode": "GBP", "date": 700000000, "method": "cash", "note": "", "isDeleted": false,
              "createdAt": 700000000, "updatedAt": 700000000 } } }
          ]
        }
        """
        let group = try JSONDecoder().decode(ExpenseGroup.self, from: Data(json.utf8))
        let groceries = group.expenses[0]
        XCTAssertEqual(groceries.payers, [UUID(uuidString: a)!: 5000])
        XCTAssertEqual(groceries.currencyCode, "GBP")
        XCTAssertEqual(groceries.category, .general)
        XCTAssertEqual(groceries.notes, "")
        XCTAssertNil(groceries.recurrence)
        XCTAssertEqual(group.payments.count, 1)
        XCTAssertEqual(SettlementEngine.balances(for: group).map(\.cents), [1500, -1500])
        XCTAssertEqual(group.schemaVersion, ExpenseGroup.currentSchemaVersion)

        let upgraded = try JSONDecoder().decode(ExpenseGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(upgraded, group)
    }
}
