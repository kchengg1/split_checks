import XCTest
@testable import SettledCore

/// Milestone 9: cross-group friend balances, settle-all payments, CSV
/// export, and per-person statements.
final class FriendsAndReportsTests: XCTestCase {

    private let me = Person(name: "Me", colorIndex: 0)
    private let sam = Person(name: "Sam", colorIndex: 1)
    private let jo = Person(name: "Jo", colorIndex: 2)
    private let day = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func groups() -> [ExpenseGroup] {
        var trip = ExpenseGroup(name: "Trip", people: [me, sam, jo])
        // Sam paid 90 for the three of us: I owe Sam 30, Jo owes Sam 30.
        trip.apply(.addEntry(.expense(Expense(title: "Cabin", payerID: sam.id, amountCents: 9000, date: day,
                                              split: .equally(participantIDs: [me.id, sam.id, jo.id])))))
        // I paid 20 for Jo and me: Jo owes me 10.
        trip.apply(.addEntry(.expense(Expense(title: "Gas", payerID: me.id, amountCents: 2000, date: day,
                                              split: .equally(participantIDs: [me.id, jo.id])))))

        var home = ExpenseGroup(name: "Home", kind: .home, currencyCode: "EUR", people: [me, sam])
        // I paid €100 rent split evenly: Sam owes me €50.
        home.apply(.addEntry(.expense(Expense(title: "Rent", payerID: me.id, amountCents: 10000, date: day,
                                              split: .equally(participantIDs: [me.id, sam.id])))))

        var other = ExpenseGroup(name: "Not mine", people: [sam, jo])
        other.apply(.addEntry(.expense(Expense(title: "Lunch", payerID: sam.id, amountCents: 1000, date: day,
                                               split: .equally(participantIDs: [sam.id, jo.id])))))
        return [trip, home, other]
    }

    func testFriendBalancesSumAcrossGroupsPerCurrency() {
        let friends = FriendLedger.balances(groups: groups(), meID: me.id)
        XCTAssertEqual(friends.map(\.name), ["Sam", "Jo"], "biggest balance first")

        let samBalance = friends[0]
        XCTAssertEqual(samBalance.byCurrency, ["USD": -3000, "EUR": 5000])
        XCTAssertEqual(samBalance.groups.map(\.groupName).sorted(), ["Home", "Trip"])

        let joBalance = friends[1]
        XCTAssertEqual(joBalance.byCurrency, ["USD": 1000])
        XCTAssertFalse(joBalance.isSettled)

        // Groups I'm not in don't count, and settled friends still appear.
        var settled = ExpenseGroup(name: "Quiet", people: [me, jo])
        settled.apply(.addEntry(.expense(Expense(title: "Coffee", payerID: me.id, amountCents: 400,
                                                 split: .equally(participantIDs: [me.id, jo.id])))))
        settled.apply(.addEntry(.payment(Payment(fromID: jo.id, toID: me.id, cents: 200))))
        let quiet = FriendLedger.balances(groups: [settled], meID: me.id)
        XCTAssertEqual(quiet.map(\.name), ["Jo"])
        XCTAssertTrue(quiet[0].isSettled)
    }

    func testFriendBalancesFollowTheGroupsSimplifyMode() {
        // Simplified: Jo owes Sam 30 and me 10; net balances are me -20,
        // Sam +60, Jo -40, so the greedy transfers are Jo→Sam 40, me→Sam 20.
        var trip = groups()[0]
        trip.simplifyDebts = true
        let friends = FriendLedger.balances(groups: [trip], meID: me.id)
        let sam = friends.first { $0.name == "Sam" }!
        let jo = friends.first { $0.name == "Jo" }!
        XCTAssertEqual(sam.byCurrency, ["USD": -2000])
        XCTAssertTrue(jo.isSettled, "with simplify on, Jo pays Sam instead of me")
    }

    func testSettleAllPaymentsZeroThePairEverywhere() {
        var all = groups()
        let payments = FriendLedger.settleUpPayments(with: sam.id, groups: all, meID: me.id, method: .venmo)
        XCTAssertEqual(payments.count, 2)
        for (groupID, payment) in payments {
            let index = all.firstIndex { $0.id == groupID }!
            all[index].apply(.addEntry(.payment(payment)))
            XCTAssertEqual(payment.method, .venmo)
        }
        let after = FriendLedger.balances(groups: all, meID: me.id).first { $0.personID == sam.id }!
        XCTAssertTrue(after.isSettled)
        // Directions: I pay Sam 30 USD in Trip, Sam pays me 50 EUR in Home.
        let usd = payments.first { $0.payment.currencyCode == "USD" }!.payment
        XCTAssertEqual(usd.fromID, me.id)
        XCTAssertEqual(usd.toID, sam.id)
        XCTAssertEqual(usd.cents, 3000)
        let eur = payments.first { $0.payment.currencyCode == "EUR" }!.payment
        XCTAssertEqual(eur.fromID, sam.id)
        XCTAssertEqual(eur.toID, me.id)
        XCTAssertEqual(eur.cents, 5000)
    }

    func testGroupCSV() {
        var group = groups()[0]
        group.apply(.addEntry(.expense(Expense(title: "Snacks, \"the good ones\"", payerID: jo.id, amountCents: 1234, date: day,
                                               split: .exactCents([me.id: 1000, jo.id: 234]), notes: "line\nbreak"))))
        group.apply(.addEntry(.payment(Payment(fromID: me.id, toID: sam.id, cents: 500, date: day))))
        let csv = GroupCSV.render(group)
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(rows[0], "Date,Type,Title,Category,Currency,Amount,Paid by,Notes,Me owes,Sam owes,Jo owes")
        XCTAssertTrue(csv.hasSuffix("\n"))
        XCTAssertTrue(csv.contains("\(GroupCSV.dateString(day)),Expense,Cabin,general,USD,90.00,Sam,,30.00,30.00,30.00"))
        XCTAssertTrue(csv.contains("\"Snacks, \"\"the good ones\"\"\""), "commas and quotes are escaped")
        XCTAssertTrue(csv.contains("\"line\nbreak\""))
        XCTAssertTrue(csv.contains("Payment,Payment to Sam,payment,USD,5.00,Me,,0.00,5.00,0.00"))
        XCTAssertEqual(GroupCSV.amountString(-5), "-0.05")
    }

    func testStatementTotals() {
        var group = groups()[0]
        group.apply(.addEntry(.payment(Payment(fromID: me.id, toID: sam.id, cents: 1500, date: day))))
        let statement = Statement.make(for: me.id, in: group)
        XCTAssertEqual(statement.personName, "Me")
        XCTAssertEqual(statement.groupName, "Trip")
        XCTAssertEqual(statement.lines.map(\.title), ["Cabin", "Gas", "Payment to Sam"])
        XCTAssertEqual(statement.lines.map(\.netCents), [-3000, 1000, 1500])
        XCTAssertEqual(statement.totals.count, 1)
        XCTAssertEqual(statement.totals[0].currencyCode, "USD")
        XCTAssertEqual(statement.totals[0].paidCents, 3500)
        XCTAssertEqual(statement.totals[0].owedCents, 4000)
        XCTAssertEqual(statement.totals[0].netCents, -500)
        XCTAssertEqual(statement.totals[0].netCents,
                       SettlementEngine.balances(for: group).first { $0.personID == me.id }?.cents)
    }
}
