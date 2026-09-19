import Foundation
import SwiftData
import SettledCore

/// The people directory: one row per person, reused across bills and
/// groups so the same friend keeps one identity everywhere. Groups still
/// embed their own copy of each member (they are self-contained
/// documents); the directory is the index that keeps the IDs consistent.
@Model
final class SavedPerson {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorIndex: Int
    var createdAt: Date
    var lastUsedAt: Date
    var venmo: String?
    var paypal: String?
    var cashApp: String?
    var zelle: String?
    var phone: String?

    init(person: Person, createdAt: Date = .now) {
        self.id = person.id
        self.name = person.name
        self.colorIndex = person.colorIndex
        self.createdAt = createdAt
        self.lastUsedAt = createdAt
        self.venmo = person.handles.venmo
        self.paypal = person.handles.paypal
        self.cashApp = person.handles.cashApp
        self.zelle = person.handles.zelle
        self.phone = person.handles.phone
    }

    var handles: PaymentHandles {
        get { PaymentHandles(venmo: venmo, paypal: paypal, cashApp: cashApp, zelle: zelle, phone: phone) }
        set {
            venmo = newValue.venmo
            paypal = newValue.paypal
            cashApp = newValue.cashApp
            zelle = newValue.zelle
            phone = newValue.phone
        }
    }

    var person: Person {
        Person(id: id, name: name, colorIndex: colorIndex, handles: handles)
    }

    /// The same person with a chip color chosen for a particular bill or
    /// group (colors are positional so a party never gets two blues).
    func person(colorIndex: Int) -> Person {
        Person(id: id, name: name, colorIndex: colorIndex, handles: handles)
    }
}
