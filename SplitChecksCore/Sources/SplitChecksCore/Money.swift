import Foundation

/// All monetary amounts in the app are integer cents. `Money` is a small
/// namespace for formatting and parsing helpers so `Double` never touches
/// a dollar amount.
public enum Money {

    /// Formats integer cents as a localized currency string, e.g. `1450` → `"$14.50"`.
    public static func format(_ cents: Int, currencyCode: String = "USD") -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: currencyCode))
    }

    /// Parses user-entered text like `"14.50"`, `"$14.5"`, or `"14"` into cents.
    /// Returns `nil` for text that isn't a monetary amount.
    public static func parse(_ text: String) -> Int? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        cleaned.removeAll { $0 == "$" || $0 == "," }
        guard !cleaned.isEmpty, let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return (rounded as NSDecimalNumber).intValue
    }

    /// `cents` for a percentage of a base amount, rounded half-up.
    /// Used for tip suggestions (e.g. 20% of the subtotal).
    public static func percentage(_ percent: Int, of baseCents: Int) -> Int {
        let numerator = baseCents * percent
        let magnitude = abs(numerator)
        let rounded = (magnitude + 50) / 100
        return numerator < 0 ? -rounded : rounded
    }
}
