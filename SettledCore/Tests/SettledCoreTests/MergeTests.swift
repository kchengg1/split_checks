import XCTest
@testable import SettledCore

/// Milestone 10: merging two devices' copies of a group.
final class MergeTests: XCTestCase {

    private let ana = Person(name: "Ana", colorIndex: 0, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    private let ben = Person(name: "Ben", colorIndex: 1, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    private let cy = Person(name: "Cy", colorIndex: 2, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    private let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func base() -> ExpenseGroup {
        var group = ExpenseGroup(name: "Trip", people: [ana, ben], createdAt: t0)
        group.apply(.addEntry(.expense(Expense(title: "Hotel", payerID: ana.id, amountCents: 20000, date: t0,
                                               split: .equally(participantIDs: [ana.id, ben.id]),
                                               createdAt: t0))), at: t0)
        return group
    }

    /// Two copies are the same ledger, ignoring the display order of people.
    private func assertEquivalent(_ a: ExpenseGroup, _ b: ExpenseGroup, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.entries.sorted { $0.id.uuidString < $1.id.uuidString },
                       b.entries.sorted { $0.id.uuidString < $1.id.uuidString }, message, file: file, line: line)
        XCTAssertEqual(Set(a.people), Set(b.people), message, file: file, line: line)
        XCTAssertEqual(a.activity, b.activity, message, file: file, line: line)
        XCTAssertEqual(a.name, b.name, message, file: file, line: line)
        XCTAssertEqual(a.kind, b.kind, message, file: file, line: line)
        XCTAssertEqual(a.currencyCode, b.currencyCode, message, file: file, line: line)
        XCTAssertEqual(a.simplifyDebts, b.simplifyDebts, message, file: file, line: line)
        XCTAssertEqual(a.createdAt, b.createdAt, message, file: file, line: line)
        // What actually matters: the same money either way.
        let balances = { (g: ExpenseGroup) in
            Dictionary(uniqueKeysWithValues: SettlementEngine.balances(for: g).map { ($0.personID, $0.cents) })
        }
        XCTAssertEqual(balances(a), balances(b), message, file: file, line: line)
    }

    func testMergeIsIdempotentAndCommutative() {
        // Both phones start from the same group, then diverge.
        let original = base()
        var mine = original
        var theirs = original
        mine.apply(.addEntry(.expense(Expense(title: "Taxi", payerID: ben.id, amountCents: 3000, date: t0,
                                              split: .equally(participantIDs: [ana.id, ben.id])))), at: t0.addingTimeInterval(60))
        theirs.apply(.addMember(cy), at: t0.addingTimeInterval(30))
        theirs.apply(.addEntry(.payment(Payment(fromID: ben.id, toID: ana.id, cents: 5000, date: t0))), at: t0.addingTimeInterval(90))

        let ab = mine.merged(with: theirs)
        let ba = theirs.merged(with: mine)
        assertEquivalent(ab, ba, "merge must not depend on which side started")

        XCTAssertEqual(ab.expenses.count, 2)
        XCTAssertEqual(ab.payments.count, 1)
        XCTAssertEqual(Set(ab.people.map(\.name)), ["Ana", "Ben", "Cy"])
        XCTAssertEqual(ab.activity.count, 4)

        assertEquivalent(ab.merged(with: theirs), ab, "merging the same copy twice changes nothing")
        assertEquivalent(ab.merged(with: ab), ab, "idempotent")
        assertEquivalent(mine.merged(with: mine), mine, "idempotent on itself")
    }

    func testLaterEditWinsAndDeletionSurvivesAStaleEdit() {
        let original = base()
        let hotelID = original.expenses[0].id

        // They edited the hotel later than I did.
        var mine = original
        var hotel = mine.expenses[0]
        hotel.amountCents = 21000
        mine.apply(.updateEntry(.expense(hotel)), at: t0.addingTimeInterval(100))

        var theirs = original
        var theirHotel = theirs.expenses[0]
        theirHotel.amountCents = 25000
        theirs.apply(.updateEntry(.expense(theirHotel)), at: t0.addingTimeInterval(200))

        XCTAssertEqual(mine.merged(with: theirs).expenses[0].amountCents, 25000)
        XCTAssertEqual(theirs.merged(with: mine).expenses[0].amountCents, 25000)

        // A deletion on one phone is not resurrected by an older edit.
        var deleted = original
        deleted.apply(.deleteEntry(hotelID), at: t0.addingTimeInterval(300))
        let merged = mine.merged(with: deleted)
        XCTAssertTrue(merged.entries.first { $0.id == hotelID }!.isDeleted)
        XCTAssertTrue(merged.expenses.isEmpty)
        XCTAssertEqual(SettlementEngine.balances(for: merged).map(\.cents), [0, 0])
        assertEquivalent(merged, deleted.merged(with: mine))

        // Same timestamp: the tombstone still wins, both directions.
        var edit = original
        var e = edit.expenses[0]
        e.amountCents = 9999
        edit.apply(.updateEntry(.expense(e)), at: t0.addingTimeInterval(400))
        var tomb = original
        tomb.apply(.deleteEntry(hotelID), at: t0.addingTimeInterval(400))
        XCTAssertTrue(edit.merged(with: tomb).entries.first { $0.id == hotelID }!.isDeleted)
        XCTAssertTrue(tomb.merged(with: edit).entries.first { $0.id == hotelID }!.isDeleted)
    }

    func testSettingsAndRenamesTakeTheLatestChange() {
        let original = base()
        var mine = original
        var theirs = original
        mine.apply(.rename("My trip"), at: t0.addingTimeInterval(10))
        theirs.apply(.rename("Our trip"), at: t0.addingTimeInterval(20))
        theirs.apply(.setSimplifyDebts(true), at: t0.addingTimeInterval(20))

        XCTAssertEqual(mine.merged(with: theirs).name, "Our trip")
        XCTAssertTrue(mine.merged(with: theirs).simplifyDebts)
        assertEquivalent(mine.merged(with: theirs), theirs.merged(with: mine))

        // A person renamed on the other phone comes across.
        var renamed = original
        var person = renamed.people[1]
        person.name = "Benjamin"
        person.updatedAt = t0.addingTimeInterval(500)
        renamed.people[1] = person
        XCTAssertEqual(mine.merged(with: renamed).person(withID: ben.id)?.name, "Benjamin")
        XCTAssertEqual(renamed.merged(with: mine).person(withID: ben.id)?.name, "Benjamin")
    }

    func testSummaryDescribesWhatArrived() {
        let original = base()
        let mine = original
        var theirs = original
        theirs.apply(.addEntry(.expense(Expense(title: "Dinner", payerID: ben.id, amountCents: 4000, date: t0,
                                                split: .equally(participantIDs: [ana.id, ben.id])))), at: t0.addingTimeInterval(10))
        theirs.apply(.addEntry(.payment(Payment(fromID: ben.id, toID: ana.id, cents: 1000, date: t0))), at: t0.addingTimeInterval(20))
        theirs.apply(.addMember(cy), at: t0.addingTimeInterval(30))
        var hotel = theirs.expenses[0]
        hotel.amountCents = 22000
        theirs.apply(.updateEntry(.expense(hotel)), at: t0.addingTimeInterval(40))

        let (merged, summary) = mine.merging(theirs)
        XCTAssertEqual(summary.addedExpenses, 1)
        XCTAssertEqual(summary.addedPayments, 1)
        XCTAssertEqual(summary.updatedEntries, 1)
        XCTAssertEqual(summary.addedPeople, 1)
        XCTAssertEqual(summary.sentence, "1 new expense · 1 payment · 1 edit · 1 new member")
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(merged.expenses.count, 2)

        let (_, again) = merged.merging(theirs)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.sentence, "Nothing new")
    }

    func testDocumentRoundTrip() throws {
        var group = base()
        group.apply(.addEntry(.payment(Payment(fromID: ben.id, toID: ana.id, cents: 2500, date: t0, createdAt: t0))), at: t0)
        let document = GroupDocument(group: group, exportedBy: "Ana", exportedAt: t0)
        XCTAssertEqual(document.suggestedFileName, "Trip.settled")

        let decoded = try GroupDocument.decode(document.encoded())
        XCTAssertEqual(decoded.formatVersion, GroupDocument.currentFormatVersion)
        XCTAssertEqual(decoded.exportedBy, "Ana")
        XCTAssertEqual(decoded.exportedAt, t0)
        assertEquivalent(decoded.group, group)
        XCTAssertEqual(decoded.group, group)

        // A name that can't be a filename still produces one.
        var awkward = base()
        awkward.name = "Trip: 50/50?"
        XCTAssertEqual(GroupDocument(group: awkward).suggestedFileName, "Trip 5050.settled")
    }

    func testMergingConcurrentPaymentsKeepsBothAndBalancesStayExact() {
        // Both phones record a settle-up at the same time; both count.
        let original = base()
        var mine = original
        var theirs = original
        mine.apply(.addEntry(.payment(Payment(fromID: ben.id, toID: ana.id, cents: 4000, date: t0))), at: t0.addingTimeInterval(10))
        theirs.apply(.addEntry(.payment(Payment(fromID: ben.id, toID: ana.id, cents: 6000, date: t0))), at: t0.addingTimeInterval(10))

        let merged = mine.merged(with: theirs)
        XCTAssertEqual(merged.payments.count, 2)
        // Hotel left Ben owing 100; two payments of 40 and 60 clear it.
        XCTAssertEqual(SettlementEngine.balances(for: merged).map(\.cents), [0, 0])
        assertEquivalent(merged, theirs.merged(with: mine))
    }
}
