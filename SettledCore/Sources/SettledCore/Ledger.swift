import Foundation

/// What a group is for. Only changes iconography and wording in the UI.
public enum GroupKind: String, Codable, Sendable, CaseIterable {
    case trip, home, couple, event, other
}

/// How a reimbursement was made. Recorded for the ledger and the activity
/// feed; the app never moves money itself.
public enum PaymentMethod: String, Codable, Sendable, CaseIterable {
    case cash, venmo, paypal, cashApp, zelle, bankTransfer, other
}

/// A recorded reimbursement: `from` paid `to` this many cents. For balance
/// purposes it is exactly "an expense paid by `from` and owed entirely by
/// `to`", which is why it lives in the same ledger as expenses.
public struct Payment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var fromID: Person.ID
    public var toID: Person.ID
    public var cents: Int
    public var currencyCode: String
    public var date: Date
    public var method: PaymentMethod
    public var note: String
    public var isDeleted: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        fromID: Person.ID,
        toID: Person.ID,
        cents: Int,
        currencyCode: String = "USD",
        date: Date = .now,
        method: PaymentMethod = .other,
        note: String = "",
        isDeleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.cents = cents
        self.currencyCode = currencyCode
        self.date = date
        self.method = method
        self.note = note
        self.isDeleted = isDeleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public func references(_ personID: Person.ID) -> Bool {
        fromID == personID || toID == personID
    }
}

/// One line in a group's ledger. Balances are a fold over the live
/// (non-deleted) entries.
public enum LedgerEntry: Identifiable, Hashable, Codable, Sendable {
    case expense(Expense)
    case payment(Payment)

    public var id: UUID {
        switch self {
        case .expense(let e): return e.id
        case .payment(let p): return p.id
        }
    }

    public var date: Date {
        switch self {
        case .expense(let e): return e.date
        case .payment(let p): return p.date
        }
    }

    public var createdAt: Date {
        switch self {
        case .expense(let e): return e.createdAt
        case .payment(let p): return p.createdAt
        }
    }

    public var isDeleted: Bool {
        get {
            switch self {
            case .expense(let e): return e.isDeleted
            case .payment(let p): return p.isDeleted
            }
        }
        set {
            switch self {
            case .expense(var e): e.isDeleted = newValue; self = .expense(e)
            case .payment(var p): p.isDeleted = newValue; self = .payment(p)
            }
        }
    }

    public var updatedAt: Date {
        get {
            switch self {
            case .expense(let e): return e.updatedAt
            case .payment(let p): return p.updatedAt
            }
        }
        set {
            switch self {
            case .expense(var e): e.updatedAt = newValue; self = .expense(e)
            case .payment(var p): p.updatedAt = newValue; self = .payment(p)
            }
        }
    }

    public var expense: Expense? {
        if case .expense(let e) = self { return e }
        return nil
    }

    public var payment: Payment? {
        if case .payment(let p) = self { return p }
        return nil
    }

    public func references(_ personID: Person.ID) -> Bool {
        switch self {
        case .expense(let e): return e.references(personID)
        case .payment(let p): return p.references(personID)
        }
    }
}

/// An append-only audit trail entry. Every mutation of a group goes
/// through `ExpenseGroup.apply`, which records one of these, so the
/// activity feed, undo/restore, and (later) cross-device merging all come
/// from the same data.
public struct ActivityEvent: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case entryAdded, entryEdited, entryDeleted, entryRestored
        case memberAdded, memberRemoved
        case groupRenamed, settingsChanged
    }

    public let id: UUID
    public var at: Date
    public var kind: Kind
    /// The ledger entry or person this event is about, when there is one.
    public var subjectID: UUID?
    /// Whoever made the change on this device (`me`), if known.
    public var actorID: Person.ID?
    /// Pre-rendered line for the feed, e.g. `Added "Dinner": $120.00, paid by Alice`.
    public var summary: String
    /// The entry as it was before an edit or delete, so it can be shown
    /// or restored without diffing.
    public var before: LedgerEntry?

    public init(
        id: UUID = UUID(),
        at: Date = .now,
        kind: Kind,
        subjectID: UUID? = nil,
        actorID: Person.ID? = nil,
        summary: String,
        before: LedgerEntry? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.subjectID = subjectID
        self.actorID = actorID
        self.summary = summary
        self.before = before
    }
}

/// The only way to mutate a group. See `ExpenseGroup.apply`.
public enum GroupChange: Hashable, Sendable {
    case addEntry(LedgerEntry)
    case updateEntry(LedgerEntry)
    case deleteEntry(UUID)
    case restoreEntry(UUID)
    case addMember(Person)
    /// Ignored when the person appears in any entry, deleted or not, so
    /// balances stay consistent.
    case removeMember(Person.ID)
    case rename(String)
    case setSimplifyDebts(Bool)
    case setKind(GroupKind)
    /// Changes the group's default currency. Existing expenses keep the
    /// currency they were entered in.
    case setCurrency(String)
}
