import Foundation

/// One piece of recognized text with its normalized position on the receipt
/// image (0...1, bottom-left origin — Vision's convention). The app maps
/// `VNRecognizedTextObservation` into this so the parser stays UI-free
/// and testable anywhere.
public struct TextObservation: Hashable, Sendable {
    public var text: String
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var midY: Double { y + height / 2 }
}

/// What the parser could make of a receipt. Items are a *draft for the user
/// to confirm* — OCR is good but not gospel, so the UI compares
/// `itemsSubtotalCents` against the printed `subtotalCents` as a checksum.
public struct ParsedReceipt: Sendable {
    public var merchantName: String?
    public var items: [LineItem]
    public var subtotalCents: Int?
    public var taxCents: Int?
    public var tipCents: Int?
    public var totalCents: Int?

    public var itemsSubtotalCents: Int { items.reduce(0) { $0 + $1.priceCents } }
    /// nil when the receipt printed no subtotal to check against.
    public var subtotalMatchesItems: Bool? { subtotalCents.map { $0 == itemsSubtotalCents } }
}

/// Turns positioned OCR text into line items and receipt totals.
///
/// Strategy: cluster observations into visual rows by vertical midpoint
/// (receipts are columnar — item names left, prices right, so a row may be
/// one observation or several). Then classify each row by its trailing
/// amount and keywords. Everything is deterministic string handling; the
/// heuristics were tuned against fixture receipts in the test suite.
public enum ReceiptParser {

    static let paymentWords: Set<String> = [
        "CASH", "CHANGE", "VISA", "MASTERCARD", "MC", "AMEX", "DISCOVER",
        "DEBIT", "CREDIT", "CARD", "PAYMENT", "TENDER", "TENDERED",
        "AUTH", "APPROVED", "APPROVAL"
    ]
    static let taxWords: Set<String> = ["GST", "HST", "PST", "VAT"]
    /// Exact words only: "TIPS" must not match, or "STEAK TIPS" becomes a tip.
    static let tipWords: Set<String> = ["TIP", "GRATUITY"]

    public static func parse(_ observations: [TextObservation]) -> ParsedReceipt {
        let rows = clusterRows(observations)

        var items: [LineItem] = []
        var merchantName: String?
        var subtotalCents: Int?
        var taxCents: Int?
        var tipCents: Int?
        var totalCents: Int?
        var sawAmountRow = false

        for row in rows {
            let joined = row.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let confidence = row.map(\.confidence).min() ?? 0
            let tokens = joined.split(separator: " ").map(String.init)

            guard let (cents, consumed) = extractTrailingAmount(tokens) else {
                // No amount: merchant candidate above the first priced row,
                // otherwise a modifier/address/decoration line we skip.
                if !sawAmountRow && merchantName == nil {
                    let letters = joined.filter(\.isLetter).count
                    let digits = joined.filter(isASCIIDigit).count
                    let words = wordTokens(joined)
                    if letters >= 3 && digits < 3 && words.isDisjoint(with: paymentWords) {
                        merchantName = cleanName(joined)
                    }
                }
                continue
            }

            let nameTokens = Array(tokens.dropLast(consumed))
            let name = cleanName(nameTokens.joined(separator: " "))
            let words = wordTokens(name)
            let squash = squashed(name)

            if !words.isDisjoint(with: paymentWords) {
                // "VISA 23.68", "TOTAL TENDERED 30.00", "CHANGE DUE 2.84"
            } else if squash.contains("SUBTOTAL") {
                subtotalCents = cents
            } else if squash.contains("TOTAL") || squash.contains("AMOUNTDUE") || squash.contains("BALANCEDUE") {
                totalCents = cents
            } else if squash.contains("TAX") || !words.isDisjoint(with: taxWords) {
                taxCents = (taxCents ?? 0) + cents
            } else if !words.isDisjoint(with: tipWords) || squash.contains("SERVICECHARGE") {
                tipCents = (tipCents ?? 0) + cents
            } else {
                let (quantity, remaining) = parseQuantity(nameTokens)
                let itemName = cleanName(remaining.joined(separator: " "))
                // Requiring a letter drops unit-price detail rows ("2 @ 3.00")
                // and numeric junk.
                if itemName.contains(where: \.isLetter) {
                    items.append(LineItem(name: itemName,
                                          quantity: quantity,
                                          priceCents: cents,
                                          ocrConfidence: confidence))
                }
            }
            sawAmountRow = true
        }

        return ParsedReceipt(
            merchantName: merchantName,
            items: items,
            subtotalCents: subtotalCents,
            taxCents: taxCents,
            tipCents: tipCents,
            totalCents: totalCents
        )
    }

    // MARK: - Row clustering

    /// Groups observations into visual rows: two observations share a row when
    /// their vertical midpoints are within half the taller one's height.
    /// Rows come back top-to-bottom, observations within a row left-to-right.
    static func clusterRows(_ observations: [TextObservation]) -> [[TextObservation]] {
        let sorted = observations.sorted { $0.midY > $1.midY }
        var rows: [[TextObservation]] = []
        for observation in sorted {
            if let anchor = rows.last?.first,
               abs(anchor.midY - observation.midY) < 0.5 * max(anchor.height, observation.height) {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }

    // MARK: - Token parsing

    /// `"$14.50"` → 1450, `"4,25"` → 425, `"(3.00)"` → -300, `"1,234.56"` → 123456.
    /// Requires an explicit 2-decimal amount; bare integers and percentages
    /// return nil so "TABLE 12" and "8.875%" never become prices.
    static func parseMoneyToken(_ token: String) -> Int? {
        var t = Substring(token)
        var negative = false
        if t.hasPrefix("("), t.hasSuffix(")"), t.count >= 2 {
            negative = true
            t = t.dropFirst().dropLast()
        }
        if t.hasPrefix("-") { negative = true; t = t.dropFirst() }
        if t.hasPrefix("$") { t = t.dropFirst() }
        if t.hasSuffix("-") { negative = true; t = t.dropLast() }
        guard t.count >= 4 else { return nil }

        let separatorIndex = t.index(t.endIndex, offsetBy: -3)
        guard t[separatorIndex] == "." || t[separatorIndex] == "," else { return nil }
        let tail = t.suffix(2)
        guard tail.allSatisfy(isASCIIDigit) else { return nil }

        // Head may carry thousands separators: "1,234".
        let head = t[..<separatorIndex].filter { $0 != "," && $0 != "." }
        guard !head.isEmpty, head.count <= 7, head.allSatisfy(isASCIIDigit),
              let headValue = Int(head), let tailValue = Int(tail) else { return nil }

        let cents = headValue * 100 + tailValue
        return negative ? -cents : cents
    }

    /// Finds the row's amount at the end of its tokens, tolerating a 1-2
    /// letter tax code after it ("14.00 T"). Returns the cents and how many
    /// trailing tokens the amount consumed.
    static func extractTrailingAmount(_ tokens: [String]) -> (cents: Int, consumed: Int)? {
        guard let last = tokens.last else { return nil }
        if tokens.count >= 2, (1...2).contains(last.count),
           last.allSatisfy({ $0.isLetter && $0.isUppercase }),
           let cents = parseMoneyToken(tokens[tokens.count - 2]) {
            return (cents, 2)
        }
        if let cents = parseMoneyToken(last) {
            return (cents, 1)
        }
        return nil
    }

    /// Explicit quantities only: "2 X COKE", "2X COKE", "2 @ COKE".
    /// A bare leading number stays in the name — "12 WINGS" is a dish.
    static func parseQuantity(_ tokens: [String]) -> (quantity: Int, nameTokens: [String]) {
        guard let first = tokens.first else { return (1, tokens) }
        if tokens.count >= 2,
           let qty = Int(first), (1...99).contains(qty),
           ["X", "@"].contains(tokens[1].uppercased()) {
            return (qty, Array(tokens.dropFirst(2)))
        }
        if first.count >= 2, first.last?.uppercased() == "X",
           let qty = Int(first.dropLast()), (1...99).contains(qty) {
            return (qty, Array(tokens.dropFirst()))
        }
        return (1, tokens)
    }

    // MARK: - Text helpers

    static func wordTokens(_ text: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        for character in text.uppercased() {
            if character.isLetter || isASCIIDigit(character) {
                current.append(character)
            } else if !current.isEmpty {
                result.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { result.insert(current) }
        return result
    }

    /// Uppercased alphanumerics only, so "Sub-Total:" matches "SUBTOTAL".
    static func squashed(_ text: String) -> String {
        String(text.uppercased().filter { $0.isLetter || isASCIIDigit($0) })
    }

    static func cleanName(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t.*·-_:…"))
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
