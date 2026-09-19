import Foundation

/// Where a person can be paid back. All optional; used for settle-up
/// hand-offs (deep links) and never for anything else.
public struct PaymentHandles: Hashable, Codable, Sendable {
    public var venmo: String?
    public var paypal: String?
    public var cashApp: String?
    public var zelle: String?
    public var phone: String?

    public init(venmo: String? = nil, paypal: String? = nil, cashApp: String? = nil,
                zelle: String? = nil, phone: String? = nil) {
        self.venmo = venmo
        self.paypal = paypal
        self.cashApp = cashApp
        self.zelle = zelle
        self.phone = phone
    }

    public var isEmpty: Bool {
        [venmo, paypal, cashApp, zelle, phone].allSatisfy { ($0 ?? "").isEmpty }
    }
}

/// A diner / group member. The `id` is stable across bills and groups —
/// the app keeps a people directory so "Sam" in two groups is one Sam —
/// and `colorIndex` picks the chip color in the UI.
public struct Person: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var colorIndex: Int
    public var handles: PaymentHandles
    /// When this person's details last changed. Only used to pick a winner
    /// when two devices' copies of the same person disagree.
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, colorIndex: Int = 0,
                handles: PaymentHandles = PaymentHandles(), updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.handles = handles
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorIndex, handles, updatedAt
    }

    /// Payloads written before `handles` and `updatedAt` existed decode with
    /// empty handles and the earliest possible timestamp, so any later edit
    /// on another device wins a merge.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        handles = try container.decodeIfPresent(PaymentHandles.self, forKey: .handles) ?? PaymentHandles()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

/// One line on the receipt. `priceCents` is the total for the line
/// (quantity already multiplied in, matching how receipts print it).
/// Negative prices represent discounts/comps and split like any other item.
public struct LineItem: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var quantity: Int
    public var priceCents: Int
    /// OCR confidence in 0...1; manual entry uses 1. Lines below the UI's
    /// review threshold get flagged for the user to confirm.
    public var ocrConfidence: Double

    public init(id: UUID = UUID(), name: String, quantity: Int = 1, priceCents: Int, ocrConfidence: Double = 1.0) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.priceCents = priceCents
        self.ocrConfidence = ocrConfidence
    }
}

/// Links a person to an item. `shareWeight` supports uneven sharing:
/// weights (2, 1) split an item two-thirds / one-third.
public struct Assignment: Hashable, Codable, Sendable {
    public var itemID: LineItem.ID
    public var personID: Person.ID
    public var shareWeight: Int

    public init(itemID: LineItem.ID, personID: Person.ID, shareWeight: Int = 1) {
        self.itemID = itemID
        self.personID = personID
        self.shareWeight = shareWeight
    }
}

/// How a bill-wide amount (tax, tip) is divided among people.
public enum AllocationRule: String, Codable, Sendable, CaseIterable {
    /// In proportion to each person's item subtotal (the fair default).
    case proportional
    /// Equal share for every person on the bill.
    case even
}
