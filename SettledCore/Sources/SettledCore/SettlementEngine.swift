import Foundation

/// One person's net position in a group, in cents of one currency.
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

    public init(fromID: Person.ID, toID: Person.ID, cents: Int) {
        self.fromID = fromID
        self.toID = toID
        self.cents = cents
    }
}

/// Balances and settle-up for one currency.
public struct Settlement: Sendable {
    public var currencyCode: String
    /// Net balances in the group's people order. Always sums to zero.
    public var balances: [Balance]
    /// The payments that settle everyone up: minimized when the group
    /// simplifies debts, otherwise pairwise as incurred.
    public var transfers: [Transfer]
    public var isSimplified: Bool

    public var isSettled: Bool { transfers.isEmpty }
}

/// What one ledger entry does to balances: who paid what and who owes what,
/// in the currency balances are kept in for it.
public struct Contribution: Hashable, Sendable {
    public var currencyCode: String
    public var paid: [Person.ID: Int]
    public var owed: [Person.ID: Int]

    /// `paid − owed` per person. Sums to zero.
    public var net: [Person.ID: Int] {
        var net = paid
        for (id, cents) in owed { net[id, default: 0] -= cents }
        return net
    }
}

/// Derives balances and settle-up payments for a group. Pure functions over
/// value types, so the whole thing is unit-testable with no UI or storage.
public enum SettlementEngine {

    // MARK: - One expense

    /// The cents each person owes for one expense, in the expense's own
    /// currency and amount. Always sums to the expense amount for the
    /// computed methods; `.exactCents` is trusted. Unknown people and
    /// non-positive weights are ignored; a split with no valid participants
    /// falls back to the main payer, so money is never created or lost.
    public static func owedShares(for expense: Expense, knownPeople: Set<Person.ID>) -> [Person.ID: Int] {
        switch expense.split {
        case .equally(let participantIDs):
            let recipients = validRecipients(participantIDs, knownPeople: knownPeople, fallback: expense.payerID)
            let cents = SplitEngine.apportion(expense.amountCents, weights: Array(repeating: 1, count: recipients.count))
            return Dictionary(uniqueKeysWithValues: zip(recipients, cents))

        case .shares(let weights):
            return apportionWeighted(expense.amountCents, weights: weights, knownPeople: knownPeople, payerID: expense.payerID)

        case .percentages(let bips):
            return apportionWeighted(expense.amountCents, weights: bips, knownPeople: knownPeople, payerID: expense.payerID)

        case .exactCents(let cents):
            return cents.filter { knownPeople.contains($0.key) }

        case .adjustment(let participantIDs, let adjustments):
            let recipients = validRecipients(participantIDs, knownPeople: knownPeople, fallback: expense.payerID)
            let extras = recipients.map { adjustments[$0] ?? 0 }
            let remainder = expense.amountCents - extras.reduce(0, +)
            let base = SplitEngine.apportion(remainder, weights: Array(repeating: 1, count: recipients.count))
            var result: [Person.ID: Int] = [:]
            for (index, id) in recipients.enumerated() {
                result[id] = base[index] + extras[index]
            }
            return result
        }
    }

    private static func validRecipients(_ ids: [Person.ID], knownPeople: Set<Person.ID>, fallback: Person.ID) -> [Person.ID] {
        var seen: Set<Person.ID> = []
        let valid = ids.filter { knownPeople.contains($0) && seen.insert($0).inserted }
        return valid.isEmpty ? [fallback] : valid
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
        let ids = entries.keys.sorted { $0.uuidString < $1.uuidString }
        let cents = SplitEngine.apportion(amount, weights: ids.map { entries[$0]! })
        return Dictionary(uniqueKeysWithValues: zip(ids, cents))
    }

    /// What one expense does to balances, after applying its conversion:
    /// paid and owed shares are scaled to the converted amount by the same
    /// largest-remainder apportionment, so they still sum exactly.
    public static func contribution(for expense: Expense, knownPeople: Set<Person.ID>) -> Contribution {
        let owed = owedShares(for: expense, knownPeople: knownPeople)
        let paid = expense.payers.filter { knownPeople.contains($0.key) }
        guard let conversion = expense.conversion else {
            return Contribution(currencyCode: expense.currencyCode, paid: paid, owed: owed)
        }
        return Contribution(
            currencyCode: conversion.currencyCode,
            paid: scale(paid, to: conversion.amountCents),
            owed: scale(owed, to: conversion.amountCents)
        )
    }

    /// What one payment does to balances.
    public static func contribution(for payment: Payment, knownPeople: Set<Person.ID>) -> Contribution? {
        guard knownPeople.contains(payment.fromID), knownPeople.contains(payment.toID) else { return nil }
        return Contribution(currencyCode: payment.currencyCode,
                            paid: [payment.fromID: payment.cents],
                            owed: [payment.toID: payment.cents])
    }

    private static func scale(_ shares: [Person.ID: Int], to total: Int) -> [Person.ID: Int] {
        let ids = shares.keys.sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return [:] }
        let weights = ids.map { max(0, shares[$0] ?? 0) }
        let cents = SplitEngine.apportion(total, weights: weights)
        return Dictionary(uniqueKeysWithValues: zip(ids, cents))
    }

    private static func contributions(for group: ExpenseGroup) -> [Contribution] {
        let known = Set(group.people.map(\.id))
        return group.liveEntries.compactMap { (entry: LedgerEntry) -> Contribution? in
            switch entry {
            case .expense(var expense):
                // Entries built outside `apply` may still carry an empty currency.
                if expense.currencyCode.isEmpty { expense.currencyCode = group.currencyCode }
                return contribution(for: expense, knownPeople: known)
            case .payment(let payment):
                return contribution(for: payment, knownPeople: known)
            }
        }
    }

    // MARK: - Currencies

    /// Every currency with a live entry, the group's own first.
    public static func currencies(in group: ExpenseGroup) -> [String] {
        var codes: Set<String> = []
        for entry in group.liveEntries {
            switch entry {
            case .expense(let e): codes.insert(e.effectiveCurrencyCode.isEmpty ? group.currencyCode : e.effectiveCurrencyCode)
            case .payment(let p): codes.insert(p.currencyCode)
            }
        }
        codes.insert(group.currencyCode)
        return [group.currencyCode] + codes.subtracting([group.currencyCode]).sorted()
    }

    // MARK: - Balances

    /// Net balance per person for one currency, in the group's people order.
    /// Sums to zero. Deleted entries don't count.
    public static func balances(for group: ExpenseGroup, currencyCode: String) -> [Balance] {
        var net = Dictionary(uniqueKeysWithValues: group.people.map { ($0.id, 0) })
        for contribution in contributions(for: group) where contribution.currencyCode == currencyCode {
            for (id, cents) in contribution.net { net[id, default: 0] += cents }
        }
        return group.people.map { Balance(personID: $0.id, cents: net[$0.id] ?? 0) }
    }

    /// Balances in the group's own currency.
    public static func balances(for group: ExpenseGroup) -> [Balance] {
        balances(for: group, currencyCode: group.currencyCode)
    }

    // MARK: - Pairwise debts

    /// Debts as they were incurred, netted per pair of people, for one
    /// currency. Within each entry, people who paid more than their share
    /// are owed by those who paid less, matched in people order (for a
    /// single payer that is simply "each participant owes the payer their
    /// share"); a payment reduces what the payer owed the payee. One
    /// transfer per pair with a non-zero net, in people order. Never
    /// rearranges who owes whom, which is what people expect unless they
    /// ask for simplification.
    public static func pairwiseDebts(for group: ExpenseGroup, currencyCode: String) -> [Transfer] {
        let order = Dictionary(uniqueKeysWithValues: group.people.enumerated().map { ($1.id, $0) })
        var owed: [Pair: Int] = [:]

        for contribution in contributions(for: group) where contribution.currencyCode == currencyCode {
            let net = contribution.net
            var creditors = net.filter { $0.value > 0 }.map { (id: $0.key, left: $0.value) }
                .sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
            var debtors = net.filter { $0.value < 0 }.map { (id: $0.key, left: -$0.value) }
                .sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
            var ci = 0, di = 0
            while ci < creditors.count && di < debtors.count {
                let pay = min(creditors[ci].left, debtors[di].left)
                owed[Pair(debtors[di].id, creditors[ci].id), default: 0] += pay
                creditors[ci].left -= pay
                debtors[di].left -= pay
                if creditors[ci].left == 0 { ci += 1 }
                if debtors[di].left == 0 { di += 1 }
            }
        }

        var transfers: [Transfer] = []
        let ids = group.people.map(\.id)
        for i in ids.indices {
            for j in ids.indices where j > i {
                let net = (owed[Pair(ids[i], ids[j])] ?? 0) - (owed[Pair(ids[j], ids[i])] ?? 0)
                if net > 0 {
                    transfers.append(Transfer(fromID: ids[i], toID: ids[j], cents: net))
                } else if net < 0 {
                    transfers.append(Transfer(fromID: ids[j], toID: ids[i], cents: -net))
                }
            }
        }
        return transfers
    }

    /// Pairwise debts in the group's own currency.
    public static func pairwiseDebts(for group: ExpenseGroup) -> [Transfer] {
        pairwiseDebts(for: group, currencyCode: group.currencyCode)
    }

    private struct Pair: Hashable {
        let from: Person.ID
        let to: Person.ID
        init(_ from: Person.ID, _ to: Person.ID) {
            self.from = from
            self.to = to
        }
    }

    // MARK: - Simplification

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

    // MARK: - Settlements

    /// Balances plus the transfers to show for one currency, honoring
    /// `group.simplifyDebts`.
    public static func settlement(for group: ExpenseGroup, currencyCode: String) -> Settlement {
        let bals = balances(for: group, currencyCode: currencyCode)
        let transfers = group.simplifyDebts ? simplify(bals) : pairwiseDebts(for: group, currencyCode: currencyCode)
        return Settlement(currencyCode: currencyCode, balances: bals, transfers: transfers, isSimplified: group.simplifyDebts)
    }

    /// The settlement in the group's own currency.
    public static func settlement(for group: ExpenseGroup) -> Settlement {
        settlement(for: group, currencyCode: group.currencyCode)
    }

    /// One settlement per currency in use, the group's own first.
    public static func settlements(for group: ExpenseGroup) -> [Settlement] {
        currencies(in: group).map { settlement(for: group, currencyCode: $0) }
    }

    /// Net of a set of transfers per person (received minus sent), for
    /// checking that a transfer list clears a balance list.
    public static func netOfTransfers(_ transfers: [Transfer], people: [Person.ID]) -> [Person.ID: Int] {
        var net = Dictionary(uniqueKeysWithValues: people.map { ($0, 0) })
        for t in transfers {
            net[t.fromID, default: 0] -= t.cents
            net[t.toID, default: 0] += t.cents
        }
        return net
    }
}
