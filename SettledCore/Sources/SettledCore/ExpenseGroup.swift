import Foundation

/// A group of people sharing costs: a trip, a household, a couple, an
/// event, or "everything else". It is a self-contained, Codable document —
/// members embedded, a ledger of expenses and payments, and the activity
/// trail — so it persists locally as one value today and is ready to be
/// exported, merged, or shared through iCloud without a rewrite.
///
/// Named `ExpenseGroup` rather than `Group` to stay clear of SwiftUI's
/// `Group` view in the app target.
public struct ExpenseGroup: Identifiable, Hashable, Codable, Sendable {
    /// Bumped when the JSON shape changes; `init(from:)` decodes every
    /// version ever shipped.
    public static let currentSchemaVersion = 4

    public let id: UUID
    public var name: String
    public var kind: GroupKind
    public var currencyCode: String
    /// When true, "settle up" shows the fewest transfers that clear every
    /// balance. When false (the default for new groups, matching what
    /// people expect), it shows debts pairwise as they were incurred.
    public var simplifyDebts: Bool
    public var people: [Person]
    public var entries: [LedgerEntry]
    public var activity: [ActivityEvent]
    public var createdAt: Date
    /// When name, kind, currency, or the simplify toggle last changed.
    /// Merging takes the settings from whichever copy changed them last.
    public var settingsUpdatedAt: Date
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        name: String,
        kind: GroupKind = .trip,
        currencyCode: String = "USD",
        simplifyDebts: Bool = false,
        people: [Person] = [],
        entries: [LedgerEntry] = [],
        activity: [ActivityEvent] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currencyCode = currencyCode
        self.simplifyDebts = simplifyDebts
        self.people = people
        self.entries = entries
        self.activity = activity
        self.createdAt = createdAt
        self.settingsUpdatedAt = createdAt
        self.schemaVersion = Self.currentSchemaVersion
    }

    /// Builds a group straight from expenses (no payments, no activity).
    /// Handy for tests and fixtures.
    public init(
        id: UUID = UUID(),
        name: String,
        kind: GroupKind = .trip,
        currencyCode: String = "USD",
        simplifyDebts: Bool = false,
        people: [Person] = [],
        expenses: [Expense],
        createdAt: Date = .now
    ) {
        self.init(id: id, name: name, kind: kind, currencyCode: currencyCode,
                  simplifyDebts: simplifyDebts, people: people,
                  entries: expenses.map { expense in
                      var normalized = expense
                      if normalized.currencyCode.isEmpty { normalized.currencyCode = currencyCode }
                      return .expense(normalized)
                  }, createdAt: createdAt)
    }

    // MARK: - Reading

    /// Entries that count: not deleted.
    public var liveEntries: [LedgerEntry] { entries.filter { !$0.isDeleted } }

    /// Live expenses, in ledger order.
    public var expenses: [Expense] { liveEntries.compactMap(\.expense) }

    /// Live payments, in ledger order.
    public var payments: [Payment] { liveEntries.compactMap(\.payment) }

    /// Sum of live expenses. Payments move money around; they don't add spend.
    public var totalCents: Int { expenses.reduce(0) { $0 + $1.amountCents } }

    public func entry(withID id: UUID) -> LedgerEntry? {
        entries.first { $0.id == id }
    }

    public func person(withID id: Person.ID) -> Person? {
        people.first { $0.id == id }
    }

    public func name(of id: Person.ID) -> String {
        person(withID: id)?.name ?? "?"
    }

    /// True when the person appears in any entry, including deleted ones
    /// (a deleted entry can be restored, so its people must stay).
    public func isReferenced(_ personID: Person.ID) -> Bool {
        entries.contains { $0.references(personID) }
    }

    // MARK: - Mutation

    /// Applies a change and records it in `activity`. Returns false (and
    /// changes nothing) when the change doesn't apply: an unknown entry,
    /// a duplicate member, removing a referenced person, and so on.
    @discardableResult
    public mutating func apply(_ change: GroupChange, by actorID: Person.ID? = nil, at now: Date = .now) -> Bool {
        switch change {
        case .addEntry(let added):
            let entry = normalized(added)
            guard self.entry(withID: entry.id) == nil else { return false }
            entries.append(entry)
            record(.entryAdded, subject: entry.id, actor: actorID, at: now,
                   summary: addedSummary(for: entry))

        case .updateEntry(let updated):
            var entry = normalized(updated)
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
            let before = entries[index]
            entry.isDeleted = before.isDeleted
            entry.updatedAt = now
            entries[index] = entry
            record(.entryEdited, subject: entry.id, actor: actorID, at: now,
                   summary: "Edited \(title(of: entry))", before: before)

        case .deleteEntry(let id):
            guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isDeleted else { return false }
            let before = entries[index]
            entries[index].isDeleted = true
            entries[index].updatedAt = now
            record(.entryDeleted, subject: id, actor: actorID, at: now,
                   summary: "Deleted \(title(of: before))", before: before)

        case .restoreEntry(let id):
            guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isDeleted else { return false }
            entries[index].isDeleted = false
            entries[index].updatedAt = now
            record(.entryRestored, subject: id, actor: actorID, at: now,
                   summary: "Restored \(title(of: entries[index]))")

        case .addMember(let person):
            guard self.person(withID: person.id) == nil else { return false }
            people.append(person)
            record(.memberAdded, subject: person.id, actor: actorID, at: now,
                   summary: "Added \(person.name)")

        case .removeMember(let personID):
            guard let person = self.person(withID: personID), !isReferenced(personID) else { return false }
            people.removeAll { $0.id == personID }
            record(.memberRemoved, subject: personID, actor: actorID, at: now,
                   summary: "Removed \(person.name)")

        case .rename(let newName):
            let trimmed = newName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != name else { return false }
            name = trimmed
            settingsUpdatedAt = now
            record(.groupRenamed, subject: nil, actor: actorID, at: now,
                   summary: "Renamed the group to \"\(trimmed)\"")

        case .setSimplifyDebts(let on):
            guard on != simplifyDebts else { return false }
            simplifyDebts = on
            settingsUpdatedAt = now
            record(.settingsChanged, subject: nil, actor: actorID, at: now,
                   summary: on ? "Turned on simplify debts" : "Turned off simplify debts")

        case .setKind(let newKind):
            guard newKind != kind else { return false }
            kind = newKind
            settingsUpdatedAt = now
            record(.settingsChanged, subject: nil, actor: actorID, at: now,
                   summary: "Changed the group type to \(newKind.rawValue)")

        case .setCurrency(let code):
            let trimmed = code.trimmingCharacters(in: .whitespaces).uppercased()
            guard trimmed.count == 3, trimmed != currencyCode else { return false }
            currencyCode = trimmed
            settingsUpdatedAt = now
            record(.settingsChanged, subject: nil, actor: actorID, at: now,
                   summary: "Changed the group currency to \(trimmed)")
        }
        return true
    }

    /// An expense with no currency is in the group's currency.
    private func normalized(_ entry: LedgerEntry) -> LedgerEntry {
        guard case .expense(var expense) = entry, expense.currencyCode.isEmpty else { return entry }
        expense.currencyCode = currencyCode
        return .expense(expense)
    }

    // MARK: - Recurring expenses

    /// Creates the copies of every recurring expense that have come due,
    /// dated on their due dates, and advances each rule. Idempotent: running
    /// it twice at the same moment creates nothing the second time. Returns
    /// how many expenses were created. There is no server to do this, so
    /// the app calls it whenever it comes to the foreground.
    @discardableResult
    public mutating func materializeRecurring(now: Date = .now, calendar: Calendar = .current, by actorID: Person.ID? = nil) -> Int {
        var created = 0
        for index in entries.indices {
            guard case .expense(var template) = entries[index], !template.isDeleted,
                  var rule = template.recurrence else { continue }
            var safety = 0
            while rule.nextDate <= now && safety < 120 {
                let copy = Expense(
                    title: template.title,
                    payers: template.payers,
                    amountCents: template.amountCents,
                    currencyCode: template.currencyCode,
                    date: rule.nextDate,
                    split: template.split,
                    category: template.category,
                    notes: template.notes,
                    conversion: template.conversion,
                    recurringSourceID: template.id,
                    createdAt: now
                )
                apply(.addEntry(.expense(copy)), by: actorID, at: now)
                rule = rule.advanced(using: calendar)
                created += 1
                safety += 1
            }
            template.recurrence = rule
            entries[index] = .expense(template)
        }
        return created
    }

    private mutating func record(_ kind: ActivityEvent.Kind, subject: UUID?, actor: Person.ID?, at: Date,
                                 summary: String, before: LedgerEntry? = nil) {
        activity.append(ActivityEvent(at: at, kind: kind, subjectID: subject, actorID: actor,
                                      summary: summary, before: before))
    }

    /// `"Dinner"` for an expense, `payment from Bob to Alice` for a payment.
    public func title(of entry: LedgerEntry) -> String {
        switch entry {
        case .expense(let e): return "\"\(e.title)\""
        case .payment(let p): return "payment from \(name(of: p.fromID)) to \(name(of: p.toID))"
        }
    }

    private func addedSummary(for entry: LedgerEntry) -> String {
        switch entry {
        case .expense(let e):
            let payers = e.payerIDs.map { name(of: $0) }
            let who = payers.count <= 1 ? (payers.first ?? "?") : payers.dropLast().joined(separator: ", ") + " and " + payers.last!
            let code = e.currencyCode.isEmpty ? currencyCode : e.currencyCode
            return "Added \"\(e.title)\": \(Money.format(e.amountCents, currencyCode: code)), paid by \(who)"
        case .payment(let p):
            return "\(name(of: p.fromID)) paid \(name(of: p.toID)) \(Money.format(p.cents, currencyCode: p.currencyCode))"
        }
    }

    // MARK: - Codable (every shipped version)

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, currencyCode, simplifyDebts, people, entries, activity, createdAt
        case settingsUpdatedAt, schemaVersion
        /// Version 1 stored a plain expenses array instead of a ledger.
        case expenses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        currencyCode = try c.decode(String.self, forKey: .currencyCode)
        people = try c.decode([Person].self, forKey: .people)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        kind = try c.decodeIfPresent(GroupKind.self, forKey: .kind) ?? .trip
        // Trips saved before the toggle existed always showed minimized
        // transfers, so they keep doing that.
        simplifyDebts = try c.decodeIfPresent(Bool.self, forKey: .simplifyDebts) ?? true
        let decodedEntries: [LedgerEntry]
        if let entries = try c.decodeIfPresent([LedgerEntry].self, forKey: .entries) {
            decodedEntries = entries
        } else {
            let expenses = try c.decodeIfPresent([Expense].self, forKey: .expenses) ?? []
            decodedEntries = expenses.map { .expense($0) }
        }
        // Expenses saved before per-expense currencies are in the group's.
        let code = currencyCode
        entries = decodedEntries.map { entry in
            guard case .expense(var expense) = entry, expense.currencyCode.isEmpty else { return entry }
            expense.currencyCode = code
            return .expense(expense)
        }
        activity = try c.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
        settingsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .settingsUpdatedAt) ?? createdAt
        schemaVersion = Self.currentSchemaVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(currencyCode, forKey: .currencyCode)
        try c.encode(simplifyDebts, forKey: .simplifyDebts)
        try c.encode(people, forKey: .people)
        try c.encode(entries, forKey: .entries)
        try c.encode(activity, forKey: .activity)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(settingsUpdatedAt, forKey: .settingsUpdatedAt)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    }
}

/// The pre-ledger name. Kept so existing call sites and tests read naturally.
public typealias Trip = ExpenseGroup
