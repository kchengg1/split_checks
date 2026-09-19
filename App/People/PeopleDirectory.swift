import Foundation
import SwiftData
import SettledCore

/// Lookups and maintenance for the people directory. Small enough to be
/// plain functions over a `ModelContext`.
enum PeopleDirectory {
    static let backfilledKey = "directory.backfilled"

    static func all(in context: ModelContext) -> [SavedPerson] {
        let descriptor = FetchDescriptor<SavedPerson>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func find(id: UUID, in context: ModelContext) -> SavedPerson? {
        let descriptor = FetchDescriptor<SavedPerson>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Case-insensitive name match. The directory is small, so filtering
    /// in memory beats fighting `#Predicate` over string folding.
    static func find(named name: String, in context: ModelContext) -> SavedPerson? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        return all(in: context).first { $0.name.lowercased() == key }
    }

    /// Reuses an existing person by name or creates one, so typing "Sam"
    /// on a bill and "sam" in a group lands on the same Sam.
    @discardableResult
    static func findOrCreate(named name: String, in context: ModelContext) -> SavedPerson {
        if let existing = find(named: name, in: context) {
            existing.lastUsedAt = .now
            return existing
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let count = (try? context.fetchCount(FetchDescriptor<SavedPerson>())) ?? 0
        let saved = SavedPerson(person: Person(name: trimmed, colorIndex: count))
        context.insert(saved)
        return saved
    }

    /// Makes sure every embedded person from a bill or group is in the
    /// directory, keyed by ID. Used when saving so nothing is orphaned.
    static func register(_ people: [Person], in context: ModelContext) {
        for person in people {
            if let existing = find(id: person.id, in: context) {
                existing.lastUsedAt = .now
            } else if find(named: person.name, in: context) == nil {
                context.insert(SavedPerson(person: person))
            }
        }
    }

    /// Bumps recency for people who were just used on a bill or group.
    static func touch(_ ids: [UUID], in context: ModelContext) {
        for id in ids {
            find(id: id, in: context)?.lastUsedAt = .now
        }
    }

    /// Writes a directory person's name and handles into every group that
    /// embeds them, so a rename shows up everywhere.
    static func propagate(_ saved: SavedPerson, in context: ModelContext) {
        let groups = (try? context.fetch(FetchDescriptor<SavedTrip>())) ?? []
        for savedGroup in groups {
            var group = savedGroup.group
            guard let index = group.people.firstIndex(where: { $0.id == saved.id }) else { continue }
            group.people[index].name = saved.name
            group.people[index].handles = saved.handles
            savedGroup.update(from: group)
        }
    }

    /// One-time import of people from data saved before the directory
    /// existed. Bills and trips each minted their own IDs for the same
    /// name, so this dedupes by name and keeps the most recent ID; older
    /// groups stay self-consistent with their embedded copies.
    static func backfillIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: backfilledKey) else { return }
        defer { defaults.set(true, forKey: backfilledKey) }

        var seen = Set(all(in: context).map { $0.name.lowercased() })
        func add(_ person: Person) {
            let key = person.name.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            context.insert(SavedPerson(person: person))
        }

        let groups = (try? context.fetch(FetchDescriptor<SavedTrip>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        for saved in groups {
            saved.group.people.forEach(add)
        }
        let bills = (try? context.fetch(FetchDescriptor<SavedBill>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        for bill in bills {
            bill.snapshot?.people.forEach(add)
        }
    }
}
