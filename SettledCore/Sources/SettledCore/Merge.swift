import Foundation

/// What a merge changed, so the app can say "3 new expenses, 1 payment"
/// before or after applying it.
public struct MergeSummary: Hashable, Sendable {
    public var addedExpenses = 0
    public var addedPayments = 0
    public var updatedEntries = 0
    public var deletedEntries = 0
    public var addedPeople = 0
    public var newActivity = 0
    public var settingsChanged = false

    public var isEmpty: Bool {
        addedExpenses == 0 && addedPayments == 0 && updatedEntries == 0
            && deletedEntries == 0 && addedPeople == 0 && newActivity == 0 && !settingsChanged
    }

    /// One line for the import sheet, e.g. "2 new expenses · 1 payment".
    public var sentence: String {
        var parts: [String] = []
        if addedExpenses > 0 { parts.append("\(addedExpenses) new expense\(addedExpenses == 1 ? "" : "s")") }
        if addedPayments > 0 { parts.append("\(addedPayments) payment\(addedPayments == 1 ? "" : "s")") }
        if updatedEntries > 0 { parts.append("\(updatedEntries) edit\(updatedEntries == 1 ? "" : "s")") }
        if deletedEntries > 0 { parts.append("\(deletedEntries) deletion\(deletedEntries == 1 ? "" : "s")") }
        if addedPeople > 0 { parts.append("\(addedPeople) new member\(addedPeople == 1 ? "" : "s")") }
        if parts.isEmpty { return settingsChanged ? "Group settings changed" : "Nothing new" }
        return parts.joined(separator: " · ")
    }
}

extension ExpenseGroup {

    /// Combines another device's copy of this group with this one.
    ///
    /// The rules, all of them order-independent so two phones that merge
    /// each other's files end up with the same ledger:
    ///
    /// - **Entries** are keyed by ID. The copy with the later `updatedAt`
    ///   wins; on a tie a deletion beats an edit, so a delete on one phone
    ///   is never resurrected by a stale edit on the other.
    /// - **People** are unioned by ID, the later `updatedAt` winning a
    ///   rename. Order follows this copy, with people only the other side
    ///   knows appended.
    /// - **Activity** is unioned by event ID and sorted by time.
    /// - **Settings** (name, kind, currency, simplify) come from whichever
    ///   copy changed them last; `createdAt` keeps the earlier date.
    ///
    /// Merging is idempotent (`a.merged(with: a) == a`) and, apart from the
    /// display order of people, commutative.
    public func merged(with other: ExpenseGroup) -> ExpenseGroup {
        merging(other).group
    }

    /// The merge plus a summary of what the other copy contributed.
    public func merging(_ other: ExpenseGroup) -> (group: ExpenseGroup, summary: MergeSummary) {
        var result = self
        var summary = MergeSummary()

        // Entries.
        var index: [UUID: Int] = [:]
        for (i, entry) in result.entries.enumerated() { index[entry.id] = i }
        for incoming in other.entries {
            guard let i = index[incoming.id] else {
                index[incoming.id] = result.entries.count
                result.entries.append(incoming)
                if incoming.isDeleted {
                    summary.deletedEntries += 1
                } else if incoming.expense != nil {
                    summary.addedExpenses += 1
                } else {
                    summary.addedPayments += 1
                }
                continue
            }
            let mine = result.entries[i]
            guard Self.wins(incoming, over: mine) else { continue }
            result.entries[i] = incoming
            if incoming.isDeleted && !mine.isDeleted {
                summary.deletedEntries += 1
            } else {
                summary.updatedEntries += 1
            }
        }

        // People.
        var peopleIndex: [Person.ID: Int] = [:]
        for (i, person) in result.people.enumerated() { peopleIndex[person.id] = i }
        for incoming in other.people {
            guard let i = peopleIndex[incoming.id] else {
                peopleIndex[incoming.id] = result.people.count
                result.people.append(incoming)
                summary.addedPeople += 1
                continue
            }
            let mine = result.people[i]
            if incoming != mine, incoming.updatedAt > mine.updatedAt {
                result.people[i] = incoming
            }
        }

        // Activity.
        var seenEvents = Set(result.activity.map(\.id))
        for event in other.activity where !seenEvents.contains(event.id) {
            seenEvents.insert(event.id)
            result.activity.append(event)
            summary.newActivity += 1
        }
        result.activity.sort { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }

        // Settings: whoever changed them last.
        if Self.settingsWin(other, over: result) {
            result.name = other.name
            result.kind = other.kind
            result.currencyCode = other.currencyCode
            result.simplifyDebts = other.simplifyDebts
            result.settingsUpdatedAt = other.settingsUpdatedAt
            summary.settingsChanged = result.name != name || result.kind != kind
                || result.currencyCode != currencyCode || result.simplifyDebts != simplifyDebts
        }
        result.createdAt = min(createdAt, other.createdAt)
        result.schemaVersion = Self.currentSchemaVersion

        // Entries that arrived with no currency (an older payload) take the
        // merged group's.
        let code = result.currencyCode
        result.entries = result.entries.map { entry in
            guard case .expense(var expense) = entry, expense.currencyCode.isEmpty else { return entry }
            expense.currencyCode = code
            return .expense(expense)
        }
        return (result, summary)
    }

    /// Later `updatedAt` wins; on a tie a tombstone wins; still tied, the
    /// values must be equal or we keep the incumbent — either way both
    /// devices reach the same answer.
    private static func wins(_ incoming: LedgerEntry, over mine: LedgerEntry) -> Bool {
        if incoming.updatedAt != mine.updatedAt { return incoming.updatedAt > mine.updatedAt }
        if incoming.isDeleted != mine.isDeleted { return incoming.isDeleted }
        return false
    }

    /// Later settings change wins; on a tie the copies are compared by a
    /// fixed field order so both sides pick the same one.
    private static func settingsWin(_ incoming: ExpenseGroup, over mine: ExpenseGroup) -> Bool {
        if incoming.settingsUpdatedAt != mine.settingsUpdatedAt {
            return incoming.settingsUpdatedAt > mine.settingsUpdatedAt
        }
        let a = [incoming.name, incoming.kind.rawValue, incoming.currencyCode, incoming.simplifyDebts ? "1" : "0"]
        let b = [mine.name, mine.kind.rawValue, mine.currencyCode, mine.simplifyDebts ? "1" : "0"]
        return a.lexicographicallyPrecedes(b)
    }
}

/// A group written to a file: the format version plus the group itself.
/// Exported as `.settled`, imported and merged on another phone.
public struct GroupDocument: Identifiable, Codable, Sendable {
    /// Bumped if the envelope (not the group) ever changes shape.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    /// Whoever exported it, so the other phone can name the sender.
    public var exportedBy: String?
    public var group: ExpenseGroup

    public var id: UUID { group.id }

    public init(group: ExpenseGroup, exportedBy: String? = nil, exportedAt: Date = .now) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.exportedBy = exportedBy
        self.group = group
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> GroupDocument {
        try JSONDecoder().decode(GroupDocument.self, from: data)
    }

    /// A filename-safe name for the exported file.
    public var suggestedFileName: String {
        let cleaned = group.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? "Group" : trimmed) + ".settled"
    }
}
