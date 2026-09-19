import Foundation

/// A group's ledger as a spreadsheet: one row per live entry, one column per
/// member with what they owe on it. Payments are rows too.
public enum GroupCSV {

    public static func render(_ group: ExpenseGroup) -> String {
        let known = Set(group.people.map(\.id))
        var lines: [String] = []
        let header = ["Date", "Type", "Title", "Category", "Currency", "Amount", "Paid by", "Notes"]
            + group.people.map { "\($0.name) owes" }
        lines.append(header.map(escape).joined(separator: ","))

        let entries = group.liveEntries.sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
        for entry in entries {
            var row: [String]
            let owed: [Person.ID: Int]
            switch entry {
            case .expense(let e):
                let contribution = SettlementEngine.contribution(for: e, knownPeople: known)
                owed = contribution.owed
                let payers = e.payerIDs.map { group.name(of: $0) }.joined(separator: "; ")
                row = [dateString(e.date), "Expense", e.title, e.category.rawValue, contribution.currencyCode,
                       amountString(contribution.paid.values.reduce(0, +)), payers, e.notes]
            case .payment(let p):
                owed = [p.toID: p.cents]
                row = [dateString(p.date), "Payment", "Payment to \(group.name(of: p.toID))", "payment", p.currencyCode,
                       amountString(p.cents), group.name(of: p.fromID), p.note]
            }
            row += group.people.map { amountString(owed[$0.id] ?? 0) }
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func amountString(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        return "\(sign)\(abs(cents) / 100).\(String(format: "%02d", abs(cents) % 100))"
    }

    static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// One person's reimbursement statement for a group: what they paid, what
/// they owed, and the net, per entry and in total per currency.
public struct Statement: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        public let date: Date
        public let title: String
        public let currencyCode: String
        public let totalCents: Int
        public let paidCents: Int
        public let owedCents: Int
        public var netCents: Int { paidCents - owedCents }
    }

    public struct Totals: Hashable, Sendable {
        public let currencyCode: String
        public var paidCents = 0
        public var owedCents = 0
        public var netCents: Int { paidCents - owedCents }
    }

    public let personID: Person.ID
    public let personName: String
    public let groupName: String
    public let lines: [Line]
    public let totals: [Totals]

    public static func make(for personID: Person.ID, in group: ExpenseGroup) -> Statement {
        let known = Set(group.people.map(\.id))
        var lines: [Line] = []
        var totals: [String: Totals] = [:]

        for entry in group.liveEntries.sorted(by: { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }) {
            let contribution: Contribution
            let title: String
            switch entry {
            case .expense(let e):
                contribution = SettlementEngine.contribution(for: e, knownPeople: known)
                title = e.title
            case .payment(let p):
                guard let c = SettlementEngine.contribution(for: p, knownPeople: known) else { continue }
                contribution = c
                title = p.fromID == personID ? "Payment to \(group.name(of: p.toID))" : "Payment from \(group.name(of: p.fromID))"
            }
            let paid = contribution.paid[personID] ?? 0
            let owed = contribution.owed[personID] ?? 0
            guard paid != 0 || owed != 0 else { continue }
            lines.append(Line(date: entry.date, title: title, currencyCode: contribution.currencyCode,
                              totalCents: contribution.paid.values.reduce(0, +), paidCents: paid, owedCents: owed))
            var t = totals[contribution.currencyCode] ?? Totals(currencyCode: contribution.currencyCode)
            t.paidCents += paid
            t.owedCents += owed
            totals[contribution.currencyCode] = t
        }

        let ordered = SettlementEngine.currencies(in: group).compactMap { totals[$0] }
        return Statement(personID: personID, personName: group.name(of: personID), groupName: group.name,
                         lines: lines, totals: ordered)
    }
}
