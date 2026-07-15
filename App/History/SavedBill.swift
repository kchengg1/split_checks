import Foundation
import SwiftData
import SplitChecksCore

/// A finished bill in local history. Display fields are denormalized for
/// cheap list rendering and people suggestions; the full bill lives in
/// `payload` as an encoded `BillSnapshot` and the split is recomputed on read.
@Model
final class SavedBill {
    var date: Date
    var merchantName: String?
    var totalCents: Int
    var peopleNames: [String]
    var payload: Data

    init(date: Date = .now, merchantName: String?, totalCents: Int, peopleNames: [String], payload: Data) {
        self.date = date
        self.merchantName = merchantName
        self.totalCents = totalCents
        self.peopleNames = peopleNames
        self.payload = payload
    }

    convenience init(snapshot: BillSnapshot, merchantName: String?) throws {
        let payload = try JSONEncoder().encode(snapshot)
        self.init(
            merchantName: merchantName,
            totalCents: snapshot.result.grandTotalCents,
            peopleNames: snapshot.people.map(\.name),
            payload: payload
        )
    }

    var snapshot: BillSnapshot? {
        try? JSONDecoder().decode(BillSnapshot.self, from: payload)
    }

    var displayName: String {
        merchantName ?? "Dinner"
    }
}
