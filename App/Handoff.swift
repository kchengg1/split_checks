import Foundation
import SettledCore

/// Deep links into payment apps for settling up. We never move money: the
/// link opens the other app prefilled, and the user records the payment
/// here once they've sent it.
enum PaymentHandoff {
    struct Option: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let url: URL
        let method: PaymentMethod
    }

    static func options(for handles: PaymentHandles, cents: Int?, currencyCode: String, note: String) -> [Option] {
        var options: [Option] = []
        let amount = cents.map { String(format: "%d.%02d", $0 / 100, $0 % 100) }
        let encodedNote = note.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let venmo = handles.venmo?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")), !venmo.isEmpty {
            var query = "txn=pay&recipients=\(venmo)&note=\(encodedNote)"
            if let amount, currencyCode == "USD" { query += "&amount=\(amount)" }
            if let url = URL(string: "venmo://paycharge?\(query)") {
                options.append(Option(id: "venmo", title: "Pay with Venmo", systemImage: "v.circle", url: url, method: .venmo))
            }
        }
        if let paypal = handles.paypal?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")), !paypal.isEmpty {
            var path = "https://paypal.me/\(paypal)"
            if let amount { path += "/\(amount)\(currencyCode)" }
            if let url = URL(string: path) {
                options.append(Option(id: "paypal", title: "Pay with PayPal", systemImage: "p.circle", url: url, method: .paypal))
            }
        }
        if let cashApp = handles.cashApp?.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")), !cashApp.isEmpty {
            var path = "https://cash.app/$\(cashApp)"
            if let amount, currencyCode == "USD" { path += "/\(amount)" }
            if let url = URL(string: path) {
                options.append(Option(id: "cashapp", title: "Pay with Cash App", systemImage: "dollarsign.circle", url: url, method: .cashApp))
            }
        }
        return options
    }
}
