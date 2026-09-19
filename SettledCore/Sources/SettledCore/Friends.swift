import Foundation

/// What one friend and I owe each other inside one group, in one currency.
/// Positive means they owe me.
public struct FriendGroupBalance: Hashable, Sendable {
    public let groupID: UUID
    public let groupName: String
    public let currencyCode: String
    public var cents: Int
}

/// My position with one person across every group we share.
public struct FriendBalance: Identifiable, Hashable, Sendable {
    public var id: Person.ID { personID }
    public let personID: Person.ID
    public var name: String
    public var groups: [FriendGroupBalance]

    /// Net per currency, positive when they owe me. Zero entries omitted.
    public var byCurrency: [String: Int] {
        var net: [String: Int] = [:]
        for g in groups { net[g.currencyCode, default: 0] += g.cents }
        return net.filter { $0.value != 0 }
    }

    public var isSettled: Bool { byCurrency.isEmpty }

    /// Largest absolute amount, for sorting the friends list.
    public var magnitude: Int { byCurrency.values.map { abs($0) }.max() ?? 0 }
}

/// Cross-group balances between me and everyone else. Follows each group's
/// own settle-up mode (pairwise as incurred, or simplified) so the friends
/// list agrees with what the group screens show.
public enum FriendLedger {

    public static func balances(groups: [ExpenseGroup], meID: Person.ID) -> [FriendBalance] {
        var byFriend: [Person.ID: FriendBalance] = [:]
        var order: [Person.ID] = []

        func entry(_ id: Person.ID, name: String) -> Int {
            if let index = order.firstIndex(of: id) { return index }
            byFriend[id] = FriendBalance(personID: id, name: name, groups: [])
            order.append(id)
            return order.count - 1
        }

        for group in groups where group.person(withID: meID) != nil {
            // Everyone I share a group with is a friend, settled or not.
            for person in group.people where person.id != meID {
                _ = entry(person.id, name: person.name)
            }
            for settlement in SettlementEngine.settlements(for: group) {
                var perFriend: [Person.ID: Int] = [:]
                for transfer in settlement.transfers {
                    if transfer.fromID == meID {
                        perFriend[transfer.toID, default: 0] -= transfer.cents
                    } else if transfer.toID == meID {
                        perFriend[transfer.fromID, default: 0] += transfer.cents
                    }
                }
                for (friendID, cents) in perFriend where cents != 0 {
                    _ = entry(friendID, name: group.name(of: friendID))
                    byFriend[friendID]?.groups.append(FriendGroupBalance(
                        groupID: group.id, groupName: group.name, currencyCode: settlement.currencyCode, cents: cents))
                }
            }
        }

        return order.compactMap { byFriend[$0] }
            .sorted { ($0.magnitude, $1.name) > ($1.magnitude, $0.name) }
    }

    /// The payments that would settle everything between me and one friend:
    /// one per group and currency with a non-zero net, in the direction of
    /// the debt. Recording them all zeroes the pair everywhere.
    public static func settleUpPayments(
        with friendID: Person.ID,
        groups: [ExpenseGroup],
        meID: Person.ID,
        date: Date = .now,
        method: PaymentMethod = .other
    ) -> [(groupID: UUID, payment: Payment)] {
        guard let friend = balances(groups: groups, meID: meID).first(where: { $0.personID == friendID }) else { return [] }
        var net: [String: Int] = [:]   // key: groupID|currency
        var meta: [String: (UUID, String)] = [:]
        for g in friend.groups {
            let key = "\(g.groupID.uuidString)|\(g.currencyCode)"
            net[key, default: 0] += g.cents
            meta[key] = (g.groupID, g.currencyCode)
        }
        return net.keys.sorted().compactMap { (key: String) -> (groupID: UUID, payment: Payment)? in
            guard let cents = net[key], cents != 0, let info = meta[key] else { return nil }
            let (groupID, code) = info
            // Positive: they owe me, so they pay me.
            let payment = cents > 0
                ? Payment(fromID: friendID, toID: meID, cents: cents, currencyCode: code, date: date, method: method)
                : Payment(fromID: meID, toID: friendID, cents: -cents, currencyCode: code, date: date, method: method)
            return (groupID: groupID, payment: payment)
        }
    }
}
