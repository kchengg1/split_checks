import SwiftUI
import SettledCore

/// A printable reimbursement statement: what one person paid and owed in a
/// group, line by line, with totals per currency.
struct StatementView: View {
    let statement: Statement

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reimbursement statement")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("\(statement.personName) · \(statement.groupName)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Generated \(Date.now.formatted(date: .long, time: .omitted)) by Settled")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Date").gridColumnAlignment(.leading)
                    Text("Item").gridColumnAlignment(.leading)
                    Text("Total").gridColumnAlignment(.trailing)
                    Text("Paid").gridColumnAlignment(.trailing)
                    Text("Owed").gridColumnAlignment(.trailing)
                    Text("Net").gridColumnAlignment(.trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(Array(statement.lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Text(line.date.formatted(date: .numeric, time: .omitted))
                        Text(line.title).lineLimit(1)
                        Text(Money.format(line.totalCents, currencyCode: line.currencyCode))
                        Text(Money.format(line.paidCents, currencyCode: line.currencyCode))
                        Text(Money.format(line.owedCents, currencyCode: line.currencyCode))
                        Text(Money.format(line.netCents, currencyCode: line.currencyCode))
                            .foregroundStyle(line.netCents < 0 ? Theme.negative : Theme.positive)
                    }
                    .font(.system(size: 11))
                    .monospacedDigit()
                }
            }

            Divider()

            ForEach(statement.totals, id: \.currencyCode) { totals in
                HStack(spacing: 24) {
                    Spacer()
                    total("Paid", totals.paidCents, totals.currencyCode)
                    total("Owed", totals.owedCents, totals.currencyCode)
                    total(totals.netCents >= 0 ? "Is owed" : "Owes", abs(totals.netCents), totals.currencyCode, bold: true)
                }
            }

            Text("Net is what \(statement.personName) is owed by the group (or owes, if negative) after every expense and recorded payment.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 612, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    private func total(_ label: String, _ cents: Int, _ code: String, bold: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(Money.format(cents, currencyCode: code))
                .font(.system(size: bold ? 14 : 12, weight: bold ? .bold : .regular, design: .rounded))
                .monospacedDigit()
        }
    }
}

enum StatementPDF {
    /// Renders a single-page (as tall as needed) US-letter-width PDF.
    @MainActor
    static func render(_ statement: Statement) -> URL? {
        let view = StatementView(statement: statement)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let height = max(792, renderer.uiImage?.size.height ?? 792)
        let name = "\(statement.personName) - \(statement.groupName) statement.pdf".replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: height)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
