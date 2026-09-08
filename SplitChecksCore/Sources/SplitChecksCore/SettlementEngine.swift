import Foundation

/// One person's net position on a trip, in cents.
/// Positive means the group owes them; negative means they owe the group.
public struct Balance: Identifiable, Hashable, Sendable {
    public var id: Person.ID { personID }
    public let personID: Person.ID
    public var cents: Int
}

/// A single "settle up" payment: `from` pays `to` this many cents.
public struct Transfer: Hashable, Sendable {
    public let fromID: Person.ID
    public let toID: Person.ID
    public let cents: Int
}

public struct Settlement: Sendable {
    /// Net balances in the trip's people order. Always sums to zero.
    public var balances: [Balance]
    /// The minimized set of payments that settles everyone up.
    public var transfers: [Transfer]
}

/// Derives balances and settle-up payments for a trip. Pure functions over
/// value types, so the whole thing is unit-testable with no UI or storage.
public enum SettlementEngine {

    /// The cents each person owes for one expense. Always sums to the
    /// expense amount for the computed methods; `.exactCents` is trusted.
    /// Unknown people and non-positive weights are ignored; an `.equally`
    /// split with no valid participants falls back to the payer, so money
    /// is never created or lost.
    public static func owedShares(for expense: Expense, knownPeople: Set<Person.ID>) -> [Person.ID: Int] {
        switch expense.split {
        case .equally(let participantIDs):
            let valid = participantIDs.filter { knownPeople.contains($0) }
            let recipients = valid.isEmpty ? [expense.payerID] : valid
            let cents = SplitEngine.apportion(expense.amountCents, weights: Array(repeating: 1, count: recipients.count))
            return Dictionary(uniqueKeysWithValues: zip(recipients, cents))

        case .shares(let weights):
            return apportionWeighted(expense.amountCents, weights: weights, knownPeople: knownPeople, payerID: expense.payerID)

        case .percentages(let bips):
            return apportionWeighted(expense.amountCents, weights: bips, knownPeople: knownPeople, payerID: expense.payerID)

        case .exactCents(let cents):
            return cents.filter { knownPeople.contains($0.key) }
        }
    }

    private static func apportionWeighted(
        _ amount: Int,
        weights: [Person.ID: Int],
        knownPeople: Set<Person.ID>,
        payerID: Person.ID
    ) -> [Person.ID: Int] {
        // Deterministic order by the weights' keys, filtered to valid people.
        let entries = weights.filter { knownPeople.contains($0.key) && $0.value > 0 }
        guard !entries.isEmpty else {
            return [payerID: amount]
        }
        let ids = Array(entries.keys)
        let cents = SplitEngine.apportion(amount, weights: ids.map { entries[$0]! })
        return Dictionary(uniqueKeysWithValues: zip(ids, cents))
    }

    /// Net balance per person, in the trip's people order. Sums to zero.
    public static func balances(for trip: Trip) -> [Balance] {
        let known = Set(trip.people.map(\.id))
        var net = Dictionary(uniqueKeysWithValues: trip.people.map { ($0.id, 0) })
        for expense in trip.expenses {
            net[expense.payerID, default: 0] += expense.amountCents
            for (personID, owed) in owedShares(for: expense, knownPeople: known) {
                net[personID, default: 0] -= owed
            }
        }
        return trip.people.map { Balance(personID: $0.id, cents: net[$0.id] ?? 0) }
    }

    /// Greedy minimum-cash-flow settlement: repeatedly send the largest
    /// remaining debt to the largest remaining credit. Produces at most
    /// `people.count - 1` transfers that clear every balance exactly.
    /// Ties break by the balances' order, so the result is deterministic.
    public static func simplify(_ balances: [Balance]) -> [Transfer] {
        var creditors = balances.enumerated()
            .filter { $0.element.cents > 0 }
            .map { (id: $0.element.personID, amount: $0.element.cents, order: $0.offset) }
            .sorted { ($0.amount, -$0.order) > ($1.amount, -$1.order) }
        var debtors = balances.enumerated()
            .filter { $0.element.cents < 0 }
            .map { (id: $0.element.personID, amount: -$0.element.cents, order: $0.offset) }
            .sorted { ($0.amount, -$0.order) > ($1.amount, -$1.order) }

        var transfers: [Transfer] = []
        var ci = 0, di = 0
        while ci < creditors.count && di < debtors.count {
            let pay = min(creditors[ci].amount, debtors[di].amount)
            transfers.append(Transfer(fromID: debtors[di].id, toID: creditors[ci].id, cents: pay))
            creditors[ci].amount -= pay
            debtors[di].amount -= pay
            if creditors[ci].amount == 0 { ci += 1 }
            if debtors[di].amount == 0 { di += 1 }
        }
        return transfers
    }

    public static func settlement(for trip: Trip) -> Settlement {
        let bals = balances(for: trip)
        return Settlement(balances: bals, transfers: simplify(bals))
    }
}
