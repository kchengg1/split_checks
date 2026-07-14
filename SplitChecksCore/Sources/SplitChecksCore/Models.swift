import Foundation

/// A diner. Reusable across bills; `colorIndex` picks the chip color in the UI.
public struct Person: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var colorIndex: Int

    public init(id: UUID = UUID(), name: String, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
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
