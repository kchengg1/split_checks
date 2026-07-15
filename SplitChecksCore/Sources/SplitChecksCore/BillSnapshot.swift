import Foundation

/// A complete, self-contained record of a finished bill. History persists
/// this as encoded data; the split is *recomputed* from it on read (the
/// engine is deterministic), so saved bills re-render exactly and the
/// storage schema stays trivial.
public struct BillSnapshot: Codable, Sendable {
    public var items: [LineItem]
    public var people: [Person]
    public var assignments: [Assignment]
    public var taxCents: Int
    public var tipCents: Int
    public var taxRule: AllocationRule
    public var tipRule: AllocationRule

    public init(
        items: [LineItem],
        people: [Person],
        assignments: [Assignment],
        taxCents: Int,
        tipCents: Int,
        taxRule: AllocationRule = .proportional,
        tipRule: AllocationRule = .proportional
    ) {
        self.items = items
        self.people = people
        self.assignments = assignments
        self.taxCents = taxCents
        self.tipCents = tipCents
        self.taxRule = taxRule
        self.tipRule = tipRule
    }

    public var splitInput: SplitInput {
        SplitInput(
            items: items,
            people: people,
            assignments: assignments,
            taxCents: taxCents,
            tipCents: tipCents,
            taxRule: taxRule,
            tipRule: tipRule
        )
    }

    public var result: SplitResult {
        SplitEngine.split(splitInput)
    }

    /// Plain-text breakdown for the group chat. One implementation shared by
    /// the live flow and saved-bill history.
    public func summaryText(merchantName: String? = nil) -> String {
        let result = self.result
        var lines: [String] = ["🧾 \(merchantName ?? "Split Checks")"]
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
