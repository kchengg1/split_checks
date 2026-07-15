import SwiftUI
import SwiftData
import SplitChecksCore

/// Past bills, newest first. Tap for the full read-only split.
struct HistoryView: View {
    @Query(sort: \SavedBill.date, order: .reverse) private var bills: [SavedBill]
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if bills.isEmpty {
                ContentUnavailableView(
                    "No bills yet",
                    systemImage: "clock",
                    description: Text("Bills you save from the split screen show up here.")
                )
            } else {
                List {
                    ForEach(bills) { bill in
                        NavigationLink {
                            SavedBillDetailView(bill: bill)
                        } label: {
                            row(bill)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            context.delete(bills[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
    }

    private func row(_ bill: SavedBill) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.displayName)
                    .font(.headline)
                Text("\(bill.date.formatted(date: .abbreviated, time: .shortened)) · \(bill.peopleNames.count) people")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.format(bill.totalCents))
                .monospacedDigit()
                .fontWeight(.semibold)
        }
    }
}
