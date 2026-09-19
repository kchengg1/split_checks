import SwiftUI
import SettledCore

/// Step 5: the payoff. One expandable card per person, totals that sum
/// exactly to the bill, and a share button for the group chat.
struct SummaryView: View {
    @Environment(BillFlowModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var expandedPersonIDs: Set<Person.ID> = []
    @State private var saved = false
    @State private var showingAddToGroup = false
    @AppStorage(Me.defaultsKey) private var meIDString = ""

    var body: some View {
        @Bindable var model = model
        let result = model.result

        List {
            if let target = model.target {
                Section {
                    Picker("Who paid?", selection: Binding(
                        get: { model.payerID ?? defaultPayerID },
                        set: { model.payerID = $0 }
                    )) {
                        ForEach(model.people) { person in
                            Text(person.id.uuidString == meIDString ? "You" : person.name).tag(Optional(person.id))
                        }
                    }
                } footer: {
                    Text("This receipt becomes an itemized expense in \(target.groupName); everyone's share is exactly their items plus tax and tip.")
                }
            }

            ForEach(result.shares) { share in
                if let person = model.people.first(where: { $0.id == share.personID }) {
                    Section {
                        personCard(person: person, share: share, result: result)
                    }
                }
            }

            HeroCard {
                Text("Grand total")
                    .font(.subheadline.weight(.medium))
                    .opacity(0.85)
                Text(Money.format(result.grandTotalCents))
                    .font(.heroAmount)
                    .monospacedDigit()
                Text("Every share adds up to the bill exactly — no lost pennies.")
                    .font(.footnote)
                    .opacity(0.85)
            }
            .cardRow()
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
            VStack(spacing: 8) {
                if let target = model.target {
                    Button {
                        finishForGroup()
                    } label: {
                        Text(target.existingExpense == nil ? "Add to \(target.groupName)" : "Update expense")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.itemizedExpense() == nil)
                } else {
                    Button {
                        saveAndFinish()
                    } label: {
                        Text("Save & start a new bill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        showingAddToGroup = true
                    } label: {
                        Label("Add to a group", systemImage: "person.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showingAddToGroup) {
            AddBillToGroupSheet(snapshot: model.snapshot, merchantName: model.merchantName) { savedGroup, _ in
                saveAndFinish(groupID: savedGroup.id)
            }
        }
    }

    private var defaultPayerID: Person.ID? {
        if let me = Me.parse(meIDString), model.people.contains(where: { $0.id == me }) { return me }
        return model.people.first?.id
    }

    /// Saves the bill to history, then pops back to a fresh item-entry screen
    /// (startOver clears the navigation path).
    private func saveAndFinish(groupID: UUID? = nil) {
        if let bill = try? SavedBill(snapshot: model.snapshot, merchantName: model.merchantName) {
            bill.groupID = groupID
            context.insert(bill)
        }
        PeopleDirectory.register(model.people, in: context)
        saved = true
        model.startOver()
    }

    /// Group mode: hand the itemized expense back to the group that started
    /// the flow. The group's handler dismisses the sheet.
    private func finishForGroup() {
        if model.payerID == nil { model.payerID = defaultPayerID }
        guard let expense = model.itemizedExpense() else { return }
        PeopleDirectory.register(model.people, in: context)
        saved = true
        model.onItemized?(expense)
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
            HStack(spacing: 12) {
                Avatar(person: person, size: 40)
                Text(person.name)
                    .font(.cardTitle)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Money.format(share.totalCents))
                    .monospacedDigit()
                    .font(.bigAmount)
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
