import Foundation

/// The bridge between the two halves of the app: a scanned, itemized bill
/// becomes a group expense whose split is exactly what the bill engine
/// computed per person.
extension Expense {

    public var isItemized: Bool { itemizedBill != nil }

    /// Builds an expense from a finished bill. `mapping` sends bill people to
    /// group members (a bill person with no mapping keeps their own ID, which
    /// is right when both came from the people directory). Two bill people
    /// mapped to the same member have their shares combined.
    public static func itemized(
        from snapshot: BillSnapshot,
        title: String,
        payers: [Person.ID: Int],
        mapping: [Person.ID: Person.ID] = [:],
        currencyCode: String = "",
        date: Date = .now,
        category: ExpenseCategory = .food,
        notes: String = "",
        receiptImageID: UUID? = nil
    ) -> Expense {
        var expense = Expense(title: title, payers: payers, amountCents: 0, currencyCode: currencyCode,
                              date: date, split: .exactCents([:]), category: category, notes: notes,
                              receiptImageID: receiptImageID)
        expense.applyItemizedBill(snapshot, mapping: mapping)
        return expense
    }

    /// Replaces the amount and split with what the bill says, keeping the
    /// expense's identity, payers, and everything else. A single payer is
    /// stretched to cover the new amount; several payers are left for the
    /// editor to reconcile (the validator will flag them).
    public mutating func applyItemizedBill(_ snapshot: BillSnapshot, mapping: [Person.ID: Person.ID] = [:]) {
        let result = snapshot.result
        var shares: [Person.ID: Int] = [:]
        for share in result.shares where share.totalCents != 0 {
            shares[mapping[share.personID] ?? share.personID, default: 0] += share.totalCents
        }
        amountCents = result.grandTotalCents
        split = .exactCents(shares)
        itemizedBill = snapshot
        if payers.count == 1, let only = payers.keys.first {
            payers = [only: amountCents]
        }
    }

    /// The bill people this expense's split refers to, after mapping — i.e.
    /// the member IDs that must exist in the group for the split to count.
    public var itemizedParticipantIDs: [Person.ID] {
        split.participantIDs
    }
}
