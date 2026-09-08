import Foundation

/// How one expense's cost is divided among the people it covers.
/// All variants resolve to integer-cents owed shares that sum exactly to the
/// expense amount (via the same largest-remainder apportionment as bills).
public enum SplitMethod: Hashable, Codable, Sendable {
    /// Divided evenly among these participants.
    case equally(participantIDs: [Person.ID])
    /// Divided in proportion to per-person weights (e.g. 2:1).
    case shares([Person.ID: Int])
    /// Divided by per-person basis points (10_000 = 100%).
    case percentages([Person.ID: Int])
    /// Exact per-person cents. The caller guarantees these sum to the amount.
    case exactCents([Person.ID: Int])
}

/// A single cost on a trip: who paid, how much, and how it's shared.
/// A scanned, itemized receipt becomes one of these with an `.exactCents`
/// split built from the per-person totals the bill engine computed.
public struct Expense: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var payerID: Person.ID
    public var amountCents: Int
    public var date: Date
    public var split: SplitMethod

    public init(
        id: UUID = UUID(),
        title: String,
        payerID: Person.ID,
        amountCents: Int,
        date: Date = .now,
        split: SplitMethod
    ) {
        self.id = id
        self.title = title
        self.payerID = payerID
        self.amountCents = amountCents
        self.date = date
        self.split = split
    }
}

/// A trip (or any shared tab): a set of people and the expenses among them.
/// One person — the treasurer — records everything; the engine derives who
/// owes whom. Fully self-contained and Codable, so a trip persists locally
/// today and is ready for optional CloudKit sharing later without a rewrite.
public struct Trip: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var currencyCode: String
    public var people: [Person]
    public var expenses: [Expense]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        currencyCode: String = "USD",
        people: [Person] = [],
        expenses: [Expense] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.currencyCode = currencyCode
        self.people = people
        self.expenses = expenses
        self.createdAt = createdAt
    }

    public var totalCents: Int { expenses.reduce(0) { $0 + $1.amountCents } }
}
