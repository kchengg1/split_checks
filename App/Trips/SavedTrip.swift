import Foundation
import SwiftData
import SplitChecksCore

/// A trip in local storage. The full `Trip` value type lives encoded in
/// `payload`; display fields are denormalized for cheap list rendering.
/// Same pattern as `SavedBill`, and just as sync-ready.
@Model
final class SavedTrip {
    var id: UUID
    var name: String
    var updatedAt: Date
    var totalCents: Int
    var peopleCount: Int
    var payload: Data

    init(trip: Trip) {
        self.id = trip.id
        self.name = trip.name
        self.updatedAt = .now
        self.totalCents = trip.totalCents
        self.peopleCount = trip.people.count
        self.payload = (try? JSONEncoder().encode(trip)) ?? Data()
    }

    /// The decoded trip, or a fresh one if the payload is somehow unreadable.
    var trip: Trip {
        (try? JSONDecoder().decode(Trip.self, from: payload)) ?? Trip(name: name)
    }

    /// Writes an edited trip back, refreshing the denormalized fields.
    func update(from trip: Trip) {
        name = trip.name
        totalCents = trip.totalCents
        peopleCount = trip.people.count
        updatedAt = .now
        if let data = try? JSONEncoder().encode(trip) { payload = data }
    }
}
