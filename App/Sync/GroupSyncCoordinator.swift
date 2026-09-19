import Foundation
import SwiftData
import SettledCore

/// Moves shared groups between iCloud and the local store. All of the
/// reconciling is `ExpenseGroup.merged(with:)`, so this only decides what
/// to fetch, what to push, and what to write down.
@MainActor
enum GroupSyncCoordinator {

    /// Pulls every shared group, merges it into the local copy (or adds it
    /// if this phone hasn't seen it), then pushes the merged result back so
    /// both sides agree. Quiet about failures: sharing is a bonus, not a
    /// requirement, and the app works offline either way.
    @discardableResult
    static func syncAll(engine: CloudSyncEngine, context: ModelContext) async -> Int {
        guard await engine.refreshAvailability() else { return 0 }
        let remote = await engine.fetchAll()
        guard !remote.isEmpty else { return 0 }

        let local = (try? context.fetch(FetchDescriptor<SavedTrip>())) ?? []
        var changed = 0

        for (incoming, zone) in remote {
            if let saved = local.first(where: { $0.id == incoming.id }) {
                let mine = saved.group
                let (merged, summary) = mine.merging(incoming)
                if !summary.isEmpty {
                    saved.update(from: merged)
                    changed += 1
                }
                saved.cloudZone = zone
                saved.lastSyncedAt = .now
                // Push only when this phone had something the cloud lacked.
                if incoming.merging(mine).summary.isEmpty == false {
                    _ = try? await engine.push(merged, zone: zone)
                }
            } else {
                let saved = SavedTrip(group: incoming)
                saved.cloudZone = zone
                saved.lastSyncedAt = .now
                context.insert(saved)
                PeopleDirectory.register(incoming.people, in: context)
                changed += 1
            }
        }
        return changed
    }

    /// Pushes one group after a local edit. No-op when it isn't shared.
    static func push(_ saved: SavedTrip, engine: CloudSyncEngine) async {
        guard let zone = saved.cloudZone else { return }
        if let merged = try? await engine.push(saved.group, zone: zone) {
            saved.update(from: merged)
            saved.lastSyncedAt = .now
        }
    }
}
