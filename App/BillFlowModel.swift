import Foundation
import Observation
import SplitChecksCore

/// Drives the one-bill flow: items → people → assign → tip & tax → summary.
/// All math is delegated to `SplitEngine`; this type only holds editable state.
@Observable
final class BillFlowModel {

    /// Navigation path for the linear flow; clearing it pops to item entry.
    var path: [BillStep] = []

    var items: [LineItem] = []
    var people: [Person] = []
    var assignments: [Assignment] = []

    /// Set when the bill came from a scan; used for the title and checksum.
    var merchantName: String?
    var scannedSubtotalCents: Int?
    var scannedTotalCents: Int?

    var taxCents: Int = 0
    /// A quick-button percentage, or nil when the user typed a custom tip.
    var tipPercent: Int? = 20
    var customTipCents: Int = 0
    var taxRule: AllocationRule = .proportional
    var tipRule: AllocationRule = .proportional

    var subtotalCents: Int { items.reduce(0) { $0 + $1.priceCents } }

    var tipCents: Int {
        if let percent = tipPercent {
            return Money.percentage(percent, of: subtotalCents)
        }
        return customTipCents
    }

    var result: SplitResult {
        SplitEngine.split(SplitInput(
            items: items,
            people: people,
            assignments: assignments,
            taxCents: taxCents,
            tipCents: tipCents,
            taxRule: taxRule,
            tipRule: tipRule
        ))
    }

    // MARK: - Items

    func addItem(name: String, priceCents: Int, quantity: Int = 1) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        items.append(LineItem(name: trimmed.isEmpty ? "Item \(items.count + 1)" : trimmed,
                              quantity: quantity,
                              priceCents: priceCents))
    }

    func updateItem(id: LineItem.ID, name: String, priceCents: Int, quantity: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        items[index].name = trimmed.isEmpty ? items[index].name : trimmed
        items[index].priceCents = priceCents
        items[index].quantity = quantity
        // The user confirmed this line, so it's no longer an OCR guess.
        items[index].ocrConfidence = 1.0
    }

    func removeItems(at offsets: IndexSet) {
        let removedIDs = Set(offsets.map { items[$0].id })
        items.remove(atOffsets: offsets)
        assignments.removeAll { removedIDs.contains($0.itemID) }
    }

    // MARK: - People

    func addPerson(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        people.append(Person(name: trimmed, colorIndex: people.count))
    }

    func removePerson(_ person: Person) {
        people.removeAll { $0.id == person.id }
        assignments.removeAll { $0.personID == person.id }
    }

    // MARK: - Assignments

    func isAssigned(item: LineItem, to person: Person) -> Bool {
        assignments.contains { $0.itemID == item.id && $0.personID == person.id }
    }

    func toggleAssignment(item: LineItem, person: Person) {
        if let index = assignments.firstIndex(where: { $0.itemID == item.id && $0.personID == person.id }) {
            assignments.remove(at: index)
        } else {
            assignments.append(Assignment(itemID: item.id, personID: person.id))
        }
    }

    func assignees(of item: LineItem) -> [Person] {
        let ids = Set(assignments.filter { $0.itemID == item.id }.map(\.personID))
        return people.filter { ids.contains($0.id) }
    }

    /// Replaces the current bill with a scanned receipt. Assignments reset
    /// because item identities changed.
    func applyParsedReceipt(_ receipt: ParsedReceipt) {
        items = receipt.items
        assignments = []
        merchantName = receipt.merchantName
        scannedSubtotalCents = receipt.subtotalCents
        scannedTotalCents = receipt.totalCents
        if let tax = receipt.taxCents { taxCents = tax }
        if let tip = receipt.tipCents, tip > 0 {
            tipPercent = nil
            customTipCents = tip
        }
    }

    /// The printed subtotal vs. the sum of parsed items — the built-in
    /// checksum for OCR quality. nil when there's nothing to check against.
    var subtotalChecksumMatches: Bool? {
        scannedSubtotalCents.map { $0 == subtotalCents }
    }

    func startOver() {
        path = []
        items = []
        people = []
        assignments = []
        merchantName = nil
        scannedSubtotalCents = nil
        scannedTotalCents = nil
        taxCents = 0
        tipPercent = 20
        customTipCents = 0
        taxRule = .proportional
        tipRule = .proportional
    }

    // MARK: - Sharing

    /// Plain-text breakdown for the group chat.
    var summaryText: String {
        let result = self.result
        var lines: [String] = ["🧾 Split Checks"]
        for share in result.shares {
            guard let person = people.first(where: { $0.id == share.personID }) else { continue }
            lines.append("")
            lines.append("\(person.name): \(Money.format(share.totalCents))")
            for item in items {
                if let cents = result.itemBreakdown[item.id]?[person.id] {
                    lines.append("  • \(item.name) \(Money.format(cents))")
                }
            }
            if share.taxCents != 0 { lines.append("  • Tax \(Money.format(share.taxCents))") }
            if share.tipCents != 0 { lines.append("  • Tip \(Money.format(share.tipCents))") }
        }
        lines.append("")
        lines.append("Total \(Money.format(result.grandTotalCents))")
        return lines.joined(separator: "\n")
    }
}
