import Foundation
import SettledCore

/// The person using this phone. Optional: without it every screen falls
/// back to neutral wording ("Alex owes Sam"); with it, "you owe Sam".
/// Stored in UserDefaults so views can observe it with `@AppStorage`.
enum Me {
    static let defaultsKey = "me.personID"
    static let onboardedKey = "me.onboarded"

    static var id: Person.ID? {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap { UUID(uuidString: $0) } }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: defaultsKey) }
    }

    static func parse(_ stored: String) -> Person.ID? {
        UUID(uuidString: stored)
    }
}

/// Wording for one group: names people, says "You" for me, and phrases
/// balances and transfers.
struct Namer {
    let group: ExpenseGroup
    let meID: Person.ID?

    func isMe(_ id: Person.ID) -> Bool { id == meID }

    func name(_ id: Person.ID) -> String {
        isMe(id) ? "You" : group.name(of: id)
    }

    func balanceLabel(_ balance: Balance) -> String {
        if balance.cents == 0 { return "settled" }
        let amount = Money.format(abs(balance.cents), currencyCode: group.currencyCode)
        if balance.cents > 0 {
            return isMe(balance.personID) ? "you get back \(amount)" : "gets back \(amount)"
        }
        return isMe(balance.personID) ? "you owe \(amount)" : "owes \(amount)"
    }

    /// For a row that already shows the person's name: "owe $12.00" after
    /// "You", "owes $12.00" after "Sam".
    func balanceVerbLabel(_ balance: Balance, currencyCode: String? = nil) -> String {
        if balance.cents == 0 { return "settled up" }
        let amount = Money.format(abs(balance.cents), currencyCode: currencyCode ?? group.currencyCode)
        let me = isMe(balance.personID)
        if balance.cents > 0 { return me ? "get back \(amount)" : "gets back \(amount)" }
        return me ? "owe \(amount)" : "owes \(amount)"
    }

    func transferLine(_ transfer: Transfer) -> String {
        let verb = isMe(transfer.fromID) ? "pay" : "pays"
        return "\(name(transfer.fromID)) \(verb) \(name(transfer.toID)) \(Money.format(transfer.cents, currencyCode: group.currencyCode))"
    }

    func paymentLine(_ payment: Payment) -> String {
        "\(name(payment.fromID)) paid \(name(payment.toID))"
    }
}

extension GroupKind {
    var title: String {
        switch self {
        case .trip: return "Trip"
        case .home: return "Home"
        case .couple: return "Couple"
        case .event: return "Event"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .trip: return "airplane"
        case .home: return "house"
        case .couple: return "heart"
        case .event: return "party.popper"
        case .other: return "folder"
        }
    }
}

extension PaymentMethod {
    var title: String {
        switch self {
        case .cash: return "Cash"
        case .venmo: return "Venmo"
        case .paypal: return "PayPal"
        case .cashApp: return "Cash App"
        case .zelle: return "Zelle"
        case .bankTransfer: return "Bank transfer"
        case .other: return "Other"
        }
    }
}

extension Person {
    /// The same person with a chip color chosen for one bill or group.
    func withColorIndex(_ index: Int) -> Person {
        Person(id: id, name: name, colorIndex: index, handles: handles)
    }
}

extension ExpenseCategory {
    var title: String {
        switch self {
        case .general: return "General"
        case .food: return "Food"
        case .drinks: return "Drinks"
        case .groceries: return "Groceries"
        case .transport: return "Transport"
        case .lodging: return "Lodging"
        case .entertainment: return "Entertainment"
        case .utilities: return "Utilities"
        case .shopping: return "Shopping"
        case .health: return "Health"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "tag"
        case .food: return "fork.knife"
        case .drinks: return "wineglass"
        case .groceries: return "cart"
        case .transport: return "car"
        case .lodging: return "bed.double"
        case .entertainment: return "ticket"
        case .utilities: return "bolt"
        case .shopping: return "bag"
        case .health: return "cross.case"
        case .other: return "ellipsis.circle"
        }
    }
}

extension RecurrenceRule.Frequency {
    var title: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

/// Currencies offered in pickers. Any 3-letter code works; these are the
/// ones people reach for.
enum Currencies {
    static let common = ["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "MXN", "CHF", "INR", "CNY", "KRW",
                         "BRL", "SEK", "NOK", "DKK", "NZD", "SGD", "HKD", "THB", "PLN", "CZK"]

    /// The common list with `code` included, so a picker never shows a
    /// selection it can't display.
    static func options(including code: String) -> [String] {
        common.contains(code) ? common : [code] + common
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }
}

extension Namer {
    /// "You paid" / "Sam paid" / "Sam and Jordan paid".
    func payersLine(_ expense: Expense) -> String {
        let names = expense.payerIDs.map { name($0) }
        switch names.count {
        case 0: return "Nobody paid"
        case 1: return "\(names[0]) paid"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last! + " paid"
        }
    }
}
