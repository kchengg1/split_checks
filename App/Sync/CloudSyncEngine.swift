import Foundation
import CloudKit
import Observation
import SettledCore

/// Live sharing through the user's own iCloud — no server of ours and no
/// account of ours. Each shared group is one record in a custom zone;
/// participants get it through a `CKShare`. Because a group is already a
/// mergeable document, syncing is "fetch, merge, save": the same
/// `ExpenseGroup.merged(with:)` that file sharing uses.
///
/// Everything here is additive. A group is local-only until someone taps
/// Share, and every failure is reported rather than thrown at the user.
@Observable
final class CloudSyncEngine {

    enum Status: Equatable {
        case unknown
        /// No iCloud account, or iCloud is off for this app.
        case unavailable(String)
        case idle
        case syncing
        case failed(String)

        var isAvailable: Bool {
            if case .unavailable = self { return false }
            if case .unknown = self { return false }
            return true
        }
    }

    static let containerIdentifier = "iCloud.com.kchengg1.settled"
    static let recordType = "SharedGroup"
    static let payloadKey = "payload"
    static let nameKey = "name"
    /// Our own zone in the private database. Sharing needs a custom zone.
    static let zoneName = "SettledGroups"

    private(set) var status: Status = .unknown

    /// Built on first use rather than at launch: constructing a CKContainer
    /// needs the iCloud entitlement, which an unsigned build (the simulator
    /// on CI) doesn't carry. `@ObservationIgnored` keeps it a real stored
    /// property — `@Observable` turns the others into computed ones, and
    /// `lazy` can't be computed.
    @ObservationIgnored
    private lazy var container = CKContainer(identifier: Self.containerIdentifier)

    // MARK: - Availability

    /// Checks the iCloud account. Safe to call often; cheap after the first.
    @discardableResult
    func refreshAvailability() async -> Bool {
        // Screenshot runs use a throwaway store and no account; iCloud has
        // nothing to offer them and would only make them flaky.
        guard !DemoData.isScreenshotRun else {
            status = .unavailable("iCloud is off in demo mode.")
            return false
        }
        do {
            switch try await container.accountStatus() {
            case .available:
                if !status.isAvailable { status = .idle }
                return true
            case .noAccount:
                status = .unavailable("Sign in to iCloud in Settings to share groups.")
            case .restricted:
                status = .unavailable("iCloud is restricted on this device.")
            case .couldNotDetermine, .temporarilyUnavailable:
                status = .unavailable("iCloud isn't reachable right now.")
            @unknown default:
                status = .unavailable("iCloud isn't available.")
            }
        } catch {
            status = .unavailable(error.localizedDescription)
        }
        return false
    }

    // MARK: - Sharing

    /// The CloudKit container, for handing to Apple's sharing screen.
    var sharingContainer: CKContainer { container }

    /// Puts a group in iCloud and returns the share to hand to the system's
    /// sharing screen. Safe to call again for an already shared group: the
    /// existing share comes back.
    func share(_ group: ExpenseGroup, zone existingZone: CloudZone?) async throws -> (share: CKShare, zone: CloudZone) {
        guard await refreshAvailability() else { throw SyncError.unavailable }
        status = .syncing
        defer { if status == .syncing { status = .idle } }

        let zone = try await ensureZone(existingZone)
        let database = self.database(for: zone)
        let recordID = CKRecord.ID(recordName: group.id.uuidString, zoneID: zone.recordZoneID)

        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
            // Already shared: keep the existing share, just push what's local.
            if let shareReference = existing.share {
                let shareRecord = try? await database.record(for: shareReference.recordID)
                if let share = shareRecord as? CKShare {
                    _ = try await save(group, into: record, database: database)
                    return (share, zone)
                }
            }
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        }

        try apply(group, to: record)
        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = group.name as CKRecordValue
        share.publicPermission = .none

        let saved = try await database.modifyRecords(saving: [record, share], deleting: [])
        for (_, result) in saved.saveResults { _ = try result.get() }
        return (share, zone)
    }

    /// Pushes local changes up, merging with whatever is already there, and
    /// returns the merged group to store locally.
    @discardableResult
    func push(_ group: ExpenseGroup, zone: CloudZone) async throws -> ExpenseGroup {
        guard await refreshAvailability() else { throw SyncError.unavailable }
        status = .syncing
        defer { if status == .syncing { status = .idle } }

        let database = self.database(for: zone)
        let recordID = CKRecord.ID(recordName: group.id.uuidString, zoneID: zone.recordZoneID)
        guard let record = try? await database.record(for: recordID) else {
            // Nothing up there (a participant's copy of a deleted share).
            throw SyncError.missingRecord
        }
        return try await save(group, into: record, database: database)
    }

    /// Everything visible in iCloud: groups I share and groups shared with
    /// me, each tagged with the zone it came from.
    func fetchAll() async -> [(group: ExpenseGroup, zone: CloudZone)] {
        guard await refreshAvailability() else { return [] }
        status = .syncing
        defer { if status == .syncing { status = .idle } }

        var found: [(ExpenseGroup, CloudZone)] = []
        var zones: [(CKRecordZone.ID, CKDatabase)] = []

        if let mine = try? await container.privateCloudDatabase.recordZone(for: Self.privateZoneID) {
            zones.append((mine.zoneID, container.privateCloudDatabase))
        }
        if let shared = try? await container.sharedCloudDatabase.allRecordZones() {
            zones.append(contentsOf: shared.map { ($0.zoneID, container.sharedCloudDatabase) })
        }

        for (zoneID, database) in zones {
            // Zone changes rather than a query: no index configuration to
            // get wrong, and deletions come through the same call.
            guard let changes = try? await database.recordZoneChanges(inZoneWith: zoneID, since: nil) else { continue }
            for change in changes.modificationResultsByID.values {
                guard let record = try? change.get().record,
                      record.recordType == Self.recordType,
                      let group = decode(record) else { continue }
                found.append((group, CloudZone(zoneID: zoneID)))
            }
        }
        return found.map { (group: $0.0, zone: $0.1) }
    }

    /// Stops sharing a group I own, leaving every copy where it is.
    func stopSharing(_ group: ExpenseGroup, zone: CloudZone) async throws {
        guard await refreshAvailability() else { throw SyncError.unavailable }
        let database = self.database(for: zone)
        let recordID = CKRecord.ID(recordName: group.id.uuidString, zoneID: zone.recordZoneID)
        guard let record = try? await database.record(for: recordID), let share = record.share else { return }
        _ = try await database.modifyRecords(saving: [], deleting: [share.recordID])
    }

    /// Takes the user up on an invitation they tapped.
    func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
    }

    // MARK: - Plumbing

    private static var privateZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private func database(for zone: CloudZone) -> CKDatabase {
        zone.isMine ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func ensureZone(_ existing: CloudZone?) async throws -> CloudZone {
        if let existing { return existing }
        let zoneID = Self.privateZoneID
        if (try? await container.privateCloudDatabase.recordZone(for: zoneID)) == nil {
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        }
        return CloudZone(zoneID: zoneID)
    }

    /// Merge-then-save, retrying once if someone else saved in between.
    @discardableResult
    private func save(_ group: ExpenseGroup, into record: CKRecord, database: CKDatabase) async throws -> ExpenseGroup {
        var record = record
        for attempt in 0..<2 {
            let merged = decode(record).map { group.merged(with: $0) } ?? group
            try apply(merged, to: record)
            do {
                _ = try await database.save(record)
                return merged
            } catch let error as CKError where error.code == .serverRecordChanged {
                guard attempt == 0, let server = error.serverRecord else { throw error }
                record = server
            }
        }
        throw SyncError.conflict
    }

    private func apply(_ group: ExpenseGroup, to record: CKRecord) throws {
        let data = try JSONEncoder().encode(group)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(group.id.uuidString)-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        record[Self.payloadKey] = CKAsset(fileURL: url)
        record[Self.nameKey] = group.name as CKRecordValue
    }

    private func decode(_ record: CKRecord) -> ExpenseGroup? {
        guard let asset = record[Self.payloadKey] as? CKAsset,
              let url = asset.fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ExpenseGroup.self, from: data)
    }

    enum SyncError: LocalizedError {
        case unavailable
        case missingRecord
        case conflict

        var errorDescription: String? {
            switch self {
            case .unavailable: return "iCloud isn't available."
            case .missingRecord: return "This group is no longer shared."
            case .conflict: return "Couldn't sync — try again."
            }
        }
    }
}

/// Which CloudKit zone a group lives in, in the little that the app needs
/// to store: a zone name plus its owner (mine, or whoever shared it).
struct CloudZone: Hashable {
    let zoneName: String
    let ownerName: String

    init(zoneID: CKRecordZone.ID) {
        zoneName = zoneID.zoneName
        ownerName = zoneID.ownerName
    }

    init(zoneName: String, ownerName: String) {
        self.zoneName = zoneName
        self.ownerName = ownerName
    }

    var recordZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }

    /// True when I own the zone, so the group lives in my private database.
    var isMine: Bool { ownerName == CKCurrentUserDefaultName }
}
