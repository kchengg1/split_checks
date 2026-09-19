import SwiftUI
import SettledCore

/// Read-only view of a saved bill: the same per-person breakdown as the
/// live summary, recomputed from the stored snapshot.
struct SavedBillDetailView: View {
    let bill: SavedBill
    @State private var showingAddToGroup = false

    var body: some View {
        Group {
            if let snapshot = bill.snapshot {
                content(snapshot: snapshot)
            } else {
                ContentUnavailableView(
                    "Couldn't open this bill",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The saved data is unreadable.")
                )
            }
        }
        .navigationTitle(bill.displayName)
    }

    private func content(snapshot: BillSnapshot) -> some View {
        let result = snapshot.result

        return List {
            Section {
                LabeledContent("Date", value: bill.date.formatted(date: .long, time: .shortened))
            }

            ForEach(result.shares) { share in
                if let person = snapshot.people.first(where: { $0.id == share.personID }) {
                    Section {
                        HStack {
                            PersonChip(person: person)
                            Spacer()
                            Text(Money.format(share.totalCents))
                                .monospacedDigit()
                                .font(.title3.weight(.semibold))
                        }
                        ForEach(snapshot.items) { item in
                            if let cents = result.itemBreakdown[item.id]?[person.id] {
                                detailRow(cents == item.priceCents ? item.name : "\(item.name) (shared)", cents)
                            }
                        }
                        if share.taxCents != 0 { detailRow("Tax", share.taxCents) }
                        if share.tipCents != 0 { detailRow("Tip", share.tipCents) }
                    }
                }
            }

            Section {
                HStack {
                    Text("Grand total").fontWeight(.semibold)
                    Spacer()
                    Text(Money.format(result.grandTotalCents))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingAddToGroup = true
                } label: {
                    Label("Add to a group", systemImage: "person.3")
                }
                ShareLink(item: snapshot.summaryText(merchantName: bill.merchantName)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingAddToGroup) {
            AddBillToGroupSheet(snapshot: snapshot, merchantName: bill.merchantName) { savedGroup, _ in
                bill.groupID = savedGroup.id
            }
        }
    }

    private func detailRow(_ label: String, _ cents: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Money.format(cents))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }
}
