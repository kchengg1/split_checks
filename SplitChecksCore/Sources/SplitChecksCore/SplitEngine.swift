import Foundation

/// Everything the engine needs to split a bill. Pure data in, pure data out.
public struct SplitInput: Sendable {
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
        taxCents: Int = 0,
        tipCents: Int = 0,
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
}

/// One person's slice of the bill.
public struct PersonShare: Identifiable, Hashable, Sendable {
    public var id: Person.ID { personID }
    public let personID: Person.ID
    public var itemsCents: Int
    public var taxCents: Int
    public var tipCents: Int
    public var totalCents: Int { itemsCents + taxCents + tipCents }
}

public struct SplitResult: Sendable {
    /// Shares in the same order as `input.people`.
    public var shares: [PersonShare]
    /// Items nobody has been assigned to yet. Excluded from all shares —
    /// the UI keeps these loud until the list is empty.
    public var unassignedItemIDs: [LineItem.ID]
    /// Per-item, per-person cents. Drives the "show the math" expansion.
    public var itemBreakdown: [LineItem.ID: [Person.ID: Int]]
    /// Sum of every item on the bill, assigned or not.
    public var subtotalCents: Int
    /// Sum of assigned items only (what the shares' item portions add to).
    public var assignedSubtotalCents: Int
    public var grandTotalCents: Int

    public var isFullyAssigned: Bool { unassignedItemIDs.isEmpty }
}

public enum SplitEngine {

    public static func split(_ input: SplitInput) -> SplitResult {
        let people = input.people
        let personIndex = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($1.id, $0) })

        var itemsCentsByPerson = [Int](repeating: 0, count: people.count)
        var itemBreakdown: [LineItem.ID: [Person.ID: Int]] = [:]
        var unassignedItemIDs: [LineItem.ID] = []

        for item in input.items {
            // Only assignments that reference a known person and carry positive
            // weight participate; anything else would corrupt the apportionment.
            let itemAssignments = input.assignments.filter {
                $0.itemID == item.id && $0.shareWeight > 0 && personIndex[$0.personID] != nil
            }
            guard !itemAssignments.isEmpty else {
                unassignedItemIDs.append(item.id)
                continue
            }
            // Deterministic order: people order on the bill, not assignment order.
            let ordered = itemAssignments.sorted { personIndex[$0.personID]! < personIndex[$1.personID]! }
            let portions = apportion(item.priceCents, weights: ordered.map(\.shareWeight))
            var breakdown: [Person.ID: Int] = [:]
            for (assignment, cents) in zip(ordered, portions) {
                breakdown[assignment.personID, default: 0] += cents
                itemsCentsByPerson[personIndex[assignment.personID]!] += cents
            }
            itemBreakdown[item.id] = breakdown
        }

        let taxByPerson = allocate(input.taxCents, rule: input.taxRule, itemsCentsByPerson: itemsCentsByPerson)
        let tipByPerson = allocate(input.tipCents, rule: input.tipRule, itemsCentsByPerson: itemsCentsByPerson)

        let shares = people.enumerated().map { index, person in
            PersonShare(
                personID: person.id,
                itemsCents: itemsCentsByPerson[index],
                taxCents: taxByPerson[index],
                tipCents: tipByPerson[index]
            )
        }

        let subtotal = input.items.reduce(0) { $0 + $1.priceCents }
        let assignedSubtotal = itemsCentsByPerson.reduce(0, +)

        return SplitResult(
            shares: shares,
            unassignedItemIDs: unassignedItemIDs,
            itemBreakdown: itemBreakdown,
            subtotalCents: subtotal,
            assignedSubtotalCents: assignedSubtotal,
            grandTotalCents: subtotal + input.taxCents + input.tipCents
        )
    }

    /// Divides `amountCents` across `weights` using the largest-remainder
    /// method: floor each proportional share, then hand out the leftover
    /// cents to the largest fractional remainders (ties go to the earlier
    /// index, so results are deterministic). The returned portions always
    /// sum exactly to `amountCents` — no pennies created or lost.
    ///
    /// Zero/negative total weight falls back to an even split. Negative
    /// amounts (discounts) are apportioned on the magnitude and negated,
    /// so a discount splits with the same fairness as a charge.
    public static func apportion(_ amountCents: Int, weights: [Int]) -> [Int] {
        precondition(!weights.isEmpty, "apportion requires at least one weight")
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else {
            return apportion(amountCents, weights: [Int](repeating: 1, count: weights.count))
        }
        if amountCents < 0 {
            return apportion(-amountCents, weights: weights).map { -$0 }
        }

        var portions = [Int](repeating: 0, count: weights.count)
        var remainders: [(index: Int, remainder: Int)] = []
        var allocated = 0
        for (index, weight) in weights.enumerated() {
            let exact = amountCents * weight
            portions[index] = exact / totalWeight
            allocated += portions[index]
            remainders.append((index, exact % totalWeight))
        }

        var leftover = amountCents - allocated
        for entry in remainders.sorted(by: { ($0.remainder, -$0.index) > ($1.remainder, -$1.index) }) {
            guard leftover > 0 else { break }
            portions[entry.index] += 1
            leftover -= 1
        }
        return portions
    }

    /// Splits a bill-wide amount (tax or tip) across people.
    /// Proportional uses item subtotals as weights; if nobody has items yet
    /// (or discounts wiped the weights out), it degrades to an even split
    /// rather than dividing by zero.
    static func allocate(_ amountCents: Int, rule: AllocationRule, itemsCentsByPerson: [Int]) -> [Int] {
        guard !itemsCentsByPerson.isEmpty, amountCents != 0 else {
            return [Int](repeating: 0, count: itemsCentsByPerson.count)
        }
        switch rule {
        case .even:
            return apportion(amountCents, weights: [Int](repeating: 1, count: itemsCentsByPerson.count))
        case .proportional:
            let weights = itemsCentsByPerson.map { max(0, $0) }
            return apportion(amountCents, weights: weights)
        }
    }
}
