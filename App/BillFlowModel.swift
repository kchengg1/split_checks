import Foundation
import Observation
import SwiftUI
import SettledCore

/// Drives the one-bill flow: items → people → assign → tip & tax → summary.
/// All math is delegated to `SplitEngine`; this type only holds editable state.
@Observable
final class BillFlowModel: Identifiable {

    let id = UUID()

    /// Navigation path; type-erased so the flow steps and saved-bill detail
    /// pushes can share one stack. Clearing it pops to item entry.
    var path = NavigationPath()

    /// When the flow was started from inside a group, where the finished
    /// bill goes: it becomes an itemized expense there instead of a history
    /// entry. `existingExpense` is set when re-editing a receipt.
    struct GroupTarget {
        let groupID: UUID
        let groupName: String
        let currencyCode: String
        let existingExpense: Expense?
    }

    var target: GroupTarget?
    /// Who paid the restaurant, for the group expense.
    var payerID: Person.ID?
    /// Called with the finished itemized expense in group mode.
    var onItemized: ((Expense) -> Void)?

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

    /// Adds a directory person (stable ID across bills and groups).
    /// Ignored if they're already on the bill.
    func addPerson(_ person: Person) {
        guard !people.contains(where: { $0.id == person.id }) else { return }
        people.append(person)
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

    /// Loads a saved bill back into the flow (re-editing an itemized
    /// expense's receipt).
    func load(snapshot: BillSnapshot, merchantName: String?) {
        items = snapshot.items
        people = snapshot.people
        assignments = snapshot.assignments
        self.merchantName = merchantName
        scannedSubtotalCents = nil
        scannedTotalCents = nil
        taxCents = snapshot.taxCents
        tipPercent = nil
        customTipCents = snapshot.tipCents
        taxRule = snapshot.taxRule
        tipRule = snapshot.tipRule
    }

    /// The group expense for the current bill, in group mode.
    func itemizedExpense() -> Expense? {
        guard let target else { return nil }
        let payer = payerID ?? people.first?.id
        guard let payer else { return nil }
        let title = (merchantName ?? "").isEmpty ? "Receipt" : merchantName!
        if var existing = target.existingExpense {
            existing.title = title
            existing.payers = [payer: 0]
            existing.applyItemizedBill(snapshot)
            existing.updatedAt = .now
            return existing
        }
        return Expense.itemized(from: snapshot, title: title, payers: [payer: 0], currencyCode: target.currencyCode)
    }

    /// The printed subtotal vs. the sum of parsed items — the built-in
    /// checksum for OCR quality. nil when there's nothing to check against.
    var subtotalChecksumMatches: Bool? {
        scannedSubtotalCents.map { $0 == subtotalCents }
    }

    func startOver() {
        path = NavigationPath()
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
        target = nil
        payerID = nil
        onItemized = nil
    }

    // MARK: - Snapshot & sharing

    var snapshot: BillSnapshot {
        BillSnapshot(
            items: items,
            people: people,
            assignments: assignments,
            taxCents: taxCents,
            tipCents: tipCents,
            taxRule: taxRule,
            tipRule: tipRule
        )
    }

    /// Plain-text breakdown for the group chat.
    var summaryText: String {
        snapshot.summaryText(merchantName: merchantName)
    }
}
