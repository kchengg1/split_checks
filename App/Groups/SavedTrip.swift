import Foundation
import SwiftData
import SettledCore

/// A group in local storage. The full `ExpenseGroup` document lives encoded
/// in `payload`; display fields are denormalized for cheap list rendering.
///
/// The class keeps its pre-ledger name (`SavedTrip`) on purpose: renaming a
/// SwiftData entity is not a lightweight migration, and the UI calls these
/// groups regardless. New columns carry defaults so existing stores open
/// unchanged, and old payloads decode through the core package's
/// version-aware decoder.
@Model
final class SavedTrip {
    var id: UUID
    var name: String
    var kindRaw: String = GroupKind.trip.rawValue
    var updatedAt: Date
    var totalCents: Int
    var peopleCount: Int
    var payload: Data
    /// Set once the group is shared through iCloud: which CloudKit zone it
    /// lives in, and who owns that zone. Nil means local-only.
    var cloudZoneName: String?
    var cloudOwnerName: String?
    var lastSyncedAt: Date?

    init(group: ExpenseGroup) {
        self.id = group.id
        self.name = group.name
        self.kindRaw = group.kind.rawValue
        self.updatedAt = .now
        self.totalCents = group.totalCents
        self.peopleCount = group.people.count
        self.payload = (try? JSONEncoder().encode(group)) ?? Data()
    }

    var kind: GroupKind {
        GroupKind(rawValue: kindRaw) ?? .trip
    }

    /// The iCloud zone this group syncs through, if it's shared.
    var cloudZone: CloudZone? {
        get {
            guard let cloudZoneName, let cloudOwnerName else { return nil }
            return CloudZone(zoneName: cloudZoneName, ownerName: cloudOwnerName)
        }
        set {
            cloudZoneName = newValue?.zoneName
            cloudOwnerName = newValue?.ownerName
        }
    }

    var isShared: Bool { cloudZoneName != nil }

    /// The decoded group, or a fresh one if the payload is somehow unreadable.
    var group: ExpenseGroup {
        (try? JSONDecoder().decode(ExpenseGroup.self, from: payload)) ?? ExpenseGroup(id: id, name: name, kind: kind)
    }

    /// Writes an edited group back, refreshing the denormalized fields.
    /// A no-op when nothing changed, so observers don't loop.
    func update(from group: ExpenseGroup) {
        guard let data = try? JSONEncoder().encode(group), data != payload else { return }
        name = group.name
        kindRaw = group.kind.rawValue
        totalCents = group.totalCents
        peopleCount = group.people.count
        updatedAt = .now
        payload = data
    }
}
