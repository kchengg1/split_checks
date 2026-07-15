import SwiftUI
import SplitChecksCore

/// Step 5: the payoff. One expandable card per person, totals that sum
/// exactly to the bill, and a share button for the group chat.
struct SummaryView: View {
    @Environment(BillFlowModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var expandedPersonIDs: Set<Person.ID> = []
    @State private var saved = false

    var body: some View {
        let result = model.result

        List {
            ForEach(result.shares) { share in
                if let person = model.people.first(where: { $0.id == share.personID }) {
                    Section {
                        personCard(person: person, share: share, result: result)
                    }
                }
            }

            Section {
                HStack {
                    Text("Grand total")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(Money.format(result.grandTotalCents))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
            } footer: {
                Text("Every share adds up to the bill exactly — no lost pennies.")
            }
        }
        .navigationTitle("The split")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.summaryText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sensoryFeedback(.success, trigger: saved)
        .safeAreaInset(edge: .bottom) {
            Button {
                saveAndFinish()
            } label: {
                Text("Save & start a new bill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    /// Saves the bill to history, then pops back to a fresh item-entry screen
    /// (startOver clears the navigation path).
    private func saveAndFinish() {
        if let bill = try? SavedBill(snapshot: model.snapshot, merchantName: model.merchantName) {
            context.insert(bill)
        }
        saved = true
        model.startOver()
    }

    @ViewBuilder
    private func personCard(person: Person, share: PersonShare, result: SplitResult) -> some View {
        let isExpanded = expandedPersonIDs.contains(person.id)

        Button {
            withAnimation {
                if isExpanded { expandedPersonIDs.remove(person.id) }
                else { expandedPersonIDs.insert(person.id) }
            }
        } label: {
            HStack {
                PersonChip(person: person)
                Spacer()
                Text(Money.format(share.totalCents))
                    .monospacedDigit()
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .accessibilityHint(Text(isExpanded ? "Collapse details" : "Show the math"))

        if isExpanded {
            ForEach(model.items) { item in
                if let cents = result.itemBreakdown[item.id]?[person.id] {
                    detailRow(label: itemLabel(item, cents: cents), cents: cents)
                }
            }
            if share.taxCents != 0 {
                detailRow(label: "Tax (\(ruleName(model.taxRule)))", cents: share.taxCents)
            }
            if share.tipCents != 0 {
                detailRow(label: "Tip (\(ruleName(model.tipRule)))", cents: share.tipCents)
            }
        }
    }

    private func itemLabel(_ item: LineItem, cents: Int) -> String {
        cents == item.priceCents ? item.name : "\(item.name) (shared)"
    }

    private func ruleName(_ rule: AllocationRule) -> String {
        rule == .proportional ? "proportional" : "even"
    }

    private func detailRow(label: String, cents: Int) -> some View {
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
