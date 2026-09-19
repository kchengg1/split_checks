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
    /// Everyone pays an equal share of what's left after per-person
    /// adjustments ("Sam +$5 for the extra drink"). Adjustments can be
    /// negative; the remainder must not be.
    case adjustment(participantIDs: [Person.ID], adjustments: [Person.ID: Int])

    /// Everyone the split names, in a deterministic order.
    public var participantIDs: [Person.ID] {
        switch self {
        case .equally(let ids), .adjustment(let ids, _): return ids
        case .shares(let map), .percentages(let map), .exactCents(let map):
            return map.keys.sorted { $0.uuidString < $1.uuidString }
        }
    }
}

/// What an expense was for. Only affects the icon and reports.
public enum ExpenseCategory: String, Codable, Sendable, CaseIterable {
    case general, food, drinks, groceries, transport, lodging, entertainment, utilities, shopping, health, other
}

/// A user-entered "this counts as" amount in another currency, so a €50
/// dinner can sit in a USD group as $54. Never fetched; always explicit.
public struct ConvertedAmount: Hashable, Codable, Sendable {
    public var currencyCode: String
    public var amountCents: Int

    public init(currencyCode: String, amountCents: Int) {
        self.currencyCode = currencyCode
        self.amountCents = amountCents
    }
}

/// Repeats an expense (rent, a subscription). The expense carrying the rule
/// is the first occurrence; `nextDate` is when the next copy is due.
public struct RecurrenceRule: Hashable, Codable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case weekly, monthly, yearly
    }

    public var frequency: Frequency
    public var nextDate: Date

    public init(frequency: Frequency, nextDate: Date) {
        self.frequency = frequency
        self.nextDate = nextDate
    }

    /// The rule with `nextDate` moved one period later.
    public func advanced(using calendar: Calendar = .current) -> RecurrenceRule {
        let component: Calendar.Component
        switch frequency {
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        }
        let next = calendar.date(byAdding: component, value: 1, to: nextDate) ?? nextDate.addingTimeInterval(86_400 * 30)
        return RecurrenceRule(frequency: frequency, nextDate: next)
    }

    /// The first due date after `date` for a rule that starts on `date`.
    public static func firstNextDate(after date: Date, frequency: Frequency, using calendar: Calendar = .current) -> Date {
        RecurrenceRule(frequency: frequency, nextDate: date).advanced(using: calendar).nextDate
    }
}

/// A single cost in a group: who paid (one or several people), how much,
/// in what currency, and how it's shared. A scanned, itemized receipt
/// becomes one of these with an `.exactCents` split built from the
/// per-person totals the bill engine computed.
///
/// Expenses are never hard-deleted from a group's ledger: `isDeleted` is a
/// tombstone so a delete can be undone, shows in the activity feed, and
/// survives a merge with another device's copy.
public struct Expense: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var amountCents: Int
    /// Empty means "the group's currency"; `ExpenseGroup` fills it in.
    public var currencyCode: String
    public var date: Date
    /// Who paid how much. Sums to `amountCents`; a single payer is one entry.
    public var payers: [Person.ID: Int]
    public var split: SplitMethod
    public var category: ExpenseCategory
    public var notes: String
    /// A receipt photo stored by the app outside the group document.
    public var receiptImageID: UUID?
    /// The scanned, itemized bill this expense was built from, when it was.
    /// The split is `.exactCents` derived from it; see `applyItemizedBill`.
    public var itemizedBill: BillSnapshot?
    /// When set, balances count this expense as that amount in that currency.
    public var conversion: ConvertedAmount?
    public var recurrence: RecurrenceRule?
    /// The recurring expense this one was generated from, if any.
    public var recurringSourceID: UUID?
    public var isDeleted: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        payers: [Person.ID: Int],
        amountCents: Int,
        currencyCode: String = "",
        date: Date = .now,
        split: SplitMethod,
        category: ExpenseCategory = .general,
        notes: String = "",
        receiptImageID: UUID? = nil,
        itemizedBill: BillSnapshot? = nil,
        conversion: ConvertedAmount? = nil,
        recurrence: RecurrenceRule? = nil,
        recurringSourceID: UUID? = nil,
        isDeleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.payers = payers
        self.amountCents = amountCents
        self.currencyCode = currencyCode
        self.date = date
        self.split = split
        self.category = category
        self.notes = notes
        self.receiptImageID = receiptImageID
        self.itemizedBill = itemizedBill
        self.conversion = conversion
        self.recurrence = recurrence
        self.recurringSourceID = recurringSourceID
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Single-payer convenience.
    public init(
        id: UUID = UUID(),
        title: String,
        payerID: Person.ID,
        amountCents: Int,
        currencyCode: String = "",
        date: Date = .now,
        split: SplitMethod,
        category: ExpenseCategory = .general,
        notes: String = "",
        receiptImageID: UUID? = nil,
        itemizedBill: BillSnapshot? = nil,
        conversion: ConvertedAmount? = nil,
        recurrence: RecurrenceRule? = nil,
        recurringSourceID: UUID? = nil,
        isDeleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.init(id: id, title: title, payers: [payerID: amountCents], amountCents: amountCents,
                  currencyCode: currencyCode, date: date, split: split, category: category, notes: notes,
                  receiptImageID: receiptImageID, itemizedBill: itemizedBill, conversion: conversion, recurrence: recurrence,
                  recurringSourceID: recurringSourceID, isDeleted: isDeleted, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// Payers by amount, largest first (ties by ID so the order is stable).
    public var payerIDs: [Person.ID] {
        payers.keys.sorted { (payers[$0]!, $1.uuidString) > (payers[$1]!, $0.uuidString) }
    }

    /// The main payer: the one who paid the most.
    public var payerID: Person.ID {
        payerIDs.first ?? UUID()
    }

    public var isMultiPayer: Bool { payers.count > 1 }

    public func paidCents(by personID: Person.ID) -> Int {
        payers[personID] ?? 0
    }

    /// The currency balances are kept in for this expense.
    public var effectiveCurrencyCode: String {
        conversion?.currencyCode ?? currencyCode
    }

    /// The amount balances use for this expense.
    public var effectiveAmountCents: Int {
        conversion?.amountCents ?? amountCents
    }

    /// True when this person paid or owes anything on this expense.
    public func references(_ personID: Person.ID) -> Bool {
        payers[personID] != nil || split.participantIDs.contains(personID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, amountCents, currencyCode, date, payers, split, category, notes
        case receiptImageID, itemizedBill, conversion, recurrence, recurringSourceID, isDeleted, createdAt, updatedAt
        /// Version 2 and earlier: a single payer.
        case payerID
    }

    /// Expenses saved before multiple payers, currencies, and the extra
    /// fields existed decode with the single payer covering the whole
    /// amount and everything else defaulted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        amountCents = try c.decode(Int.self, forKey: .amountCents)
        currencyCode = try c.decodeIfPresent(String.self, forKey: .currencyCode) ?? ""
        date = try c.decode(Date.self, forKey: .date)
        split = try c.decode(SplitMethod.self, forKey: .split)
        if let payers = try c.decodeIfPresent([Person.ID: Int].self, forKey: .payers) {
            self.payers = payers
        } else {
            let payerID = try c.decode(Person.ID.self, forKey: .payerID)
            payers = [payerID: amountCents]
        }
        category = try c.decodeIfPresent(ExpenseCategory.self, forKey: .category) ?? .general
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        receiptImageID = try c.decodeIfPresent(UUID.self, forKey: .receiptImageID)
        itemizedBill = try c.decodeIfPresent(BillSnapshot.self, forKey: .itemizedBill)
        conversion = try c.decodeIfPresent(ConvertedAmount.self, forKey: .conversion)
        recurrence = try c.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        recurringSourceID = try c.decodeIfPresent(UUID.self, forKey: .recurringSourceID)
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? date
        createdAt = created
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(amountCents, forKey: .amountCents)
        try c.encode(currencyCode, forKey: .currencyCode)
        try c.encode(date, forKey: .date)
        try c.encode(payers, forKey: .payers)
        try c.encode(split, forKey: .split)
        try c.encode(category, forKey: .category)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(receiptImageID, forKey: .receiptImageID)
        try c.encodeIfPresent(itemizedBill, forKey: .itemizedBill)
        try c.encodeIfPresent(conversion, forKey: .conversion)
        try c.encodeIfPresent(recurrence, forKey: .recurrence)
        try c.encodeIfPresent(recurringSourceID, forKey: .recurringSourceID)
        try c.encode(isDeleted, forKey: .isDeleted)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Why an expense can't be saved as entered. Pure checks the editor shows
/// inline; the engine tolerates bad input, the validator refuses it.
public enum ExpenseValidationError: Hashable, Sendable {
    case emptyTitle
    case zeroAmount
    /// Positive when payers cover less than the amount, negative when more.
    case payersDoNotSumToAmount(differenceCents: Int)
    case unknownPerson(Person.ID)
    case noParticipants
    case exactSharesDoNotSumToAmount(differenceCents: Int)
    case percentagesDoNotSumToWhole(differenceBasisPoints: Int)
    case noPositiveWeights
    case adjustmentsExceedAmount(byCents: Int)
    case conversionNotPositive
}

public enum ExpenseValidator {

    public static func validate(_ expense: Expense, in group: ExpenseGroup) -> [ExpenseValidationError] {
        var errors: [ExpenseValidationError] = []
        let known = Set(group.people.map(\.id))

        if expense.title.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.emptyTitle) }
        if expense.amountCents == 0 { errors.append(.zeroAmount) }

        let paid = expense.payers.values.reduce(0, +)
        if expense.payers.isEmpty || paid != expense.amountCents {
            errors.append(.payersDoNotSumToAmount(differenceCents: expense.amountCents - paid))
        }
        for id in expense.payers.keys where !known.contains(id) { errors.append(.unknownPerson(id)) }
        for id in expense.split.participantIDs where !known.contains(id) { errors.append(.unknownPerson(id)) }

        switch expense.split {
        case .equally(let ids):
            if ids.isEmpty { errors.append(.noParticipants) }
        case .shares(let weights):
            if !weights.values.contains(where: { $0 > 0 }) { errors.append(.noPositiveWeights) }
        case .percentages(let bips):
            let total = bips.values.reduce(0, +)
            if total != 10_000 { errors.append(.percentagesDoNotSumToWhole(differenceBasisPoints: 10_000 - total)) }
        case .exactCents(let cents):
            if cents.isEmpty { errors.append(.noParticipants) }
            let total = cents.values.reduce(0, +)
            if total != expense.amountCents { errors.append(.exactSharesDoNotSumToAmount(differenceCents: expense.amountCents - total)) }
        case .adjustment(let ids, let adjustments):
            if ids.isEmpty { errors.append(.noParticipants) }
            let adjusted = ids.reduce(0) { $0 + (adjustments[$1] ?? 0) }
            if expense.amountCents >= 0, adjusted > expense.amountCents {
                errors.append(.adjustmentsExceedAmount(byCents: adjusted - expense.amountCents))
            }
        }

        if let conversion = expense.conversion, conversion.amountCents <= 0 { errors.append(.conversionNotPositive) }
        return errors
    }
}
