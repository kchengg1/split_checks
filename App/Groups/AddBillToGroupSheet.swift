import SwiftUI
import SwiftData
import SettledCore

/// Turns a finished bill into an itemized expense in a group: pick the
/// group, match each diner to a member (or add them), say who paid.
struct AddBillToGroupSheet: View {
    let snapshot: BillSnapshot
    let merchantName: String?
    /// Called after the expense is written to the group.
    let onAdded: (SavedTrip, Expense) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedTrip.updatedAt, order: .reverse) private var groups: [SavedTrip]
    @AppStorage(Me.defaultsKey) private var meIDString = ""

    @State private var groupID: UUID?
    @State private var title: String
    /// Bill person → member. nil means "add them to the group".
    @State private var mapping: [Person.ID: Person.ID?] = [:]
    @State private var payerID: Person.ID?

    init(snapshot: BillSnapshot, merchantName: String?, onAdded: @escaping (SavedTrip, Expense) -> Void) {
        self.snapshot = snapshot
        self.merchantName = merchantName
        self.onAdded = onAdded
        _title = State(initialValue: merchantName ?? "Receipt")
    }

    private var selectedGroup: SavedTrip? { groups.first { $0.id == groupID } }
    private var group: ExpenseGroup? { selectedGroup?.group }

    /// Diners with a share on the bill.
    private var diners: [Person] {
        let result = snapshot.result
        return snapshot.people.filter { person in
            result.shares.first { $0.personID == person.id }?.totalCents != 0
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    if groups.isEmpty {
                        Text("Create a group first, from the Groups tab.")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Add to", selection: $groupID) {
                        Text("Choose a group").tag(UUID?.none)
                        ForEach(groups) { saved in
                            Label(saved.name, systemImage: saved.kind.systemImage).tag(Optional(saved.id))
                        }
                    }
                    TextField("Title", text: $title)
                }

                if let group {
                    Section {
                        ForEach(diners) { diner in
                            Picker(selection: Binding(
                                get: { mapping[diner.id] ?? nil },
                                set: { mapping[diner.id] = $0 }
                            )) {
                                Text("Add \(diner.name) to the group").tag(Person.ID?.none)
                                ForEach(group.people) { member in
                                    Text(member.name).tag(Optional(member.id))
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Avatar(person: diner, size: 24)
                                    Text(diner.name)
                                }
                            }
                        }
                    } header: {
                        Text("Who's who")
                    } footer: {
                        Text("Match each diner to a member of \(group.name).")
                    }

                    Section("Who paid the restaurant?") {
                        Picker("Paid by", selection: $payerID) {
                            ForEach(payerChoices, id: \.id) { choice in
                                Text(choice.name).tag(Optional(choice.id))
                            }
                        }
                    }

                    Section {
                        LabeledContent("Total", value: Money.format(snapshot.result.grandTotalCents, currencyCode: group.currencyCode))
                    } footer: {
                        Text("Everyone's share is exactly their items plus tax and tip.")
                    }
                }
            }
            .navigationTitle("Add to a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(group == nil || payerID == nil)
                }
            }
            .onChange(of: groupID) { autoMap() }
            .onAppear {
                if groupID == nil, groups.count == 1 { groupID = groups[0].id }
            }
        }
    }

    /// Members plus any diner about to be added, so the payer can be either.
    private var payerChoices: [(id: Person.ID, name: String)] {
        guard let group else { return [] }
        let me = Me.parse(meIDString)
        var choices = group.people.map { (id: $0.id, name: $0.id == me ? "You" : $0.name) }
        for diner in diners where (mapping[diner.id] ?? nil) == nil && !choices.contains(where: { $0.id == diner.id }) {
            choices.append((id: diner.id, name: diner.name))
        }
        return choices
    }

    /// Same ID (both from the directory) → that member; else same name;
    /// else add them.
    private func autoMap() {
        guard let group else { return }
        var result: [Person.ID: Person.ID?] = [:]
        for diner in diners {
            if group.person(withID: diner.id) != nil {
                result[diner.id] = diner.id
            } else if let byName = group.people.first(where: { $0.name.lowercased() == diner.name.lowercased() }) {
                result[diner.id] = byName.id
            } else {
                result[diner.id] = nil
            }
        }
        mapping = result
        let me = Me.parse(meIDString)
        payerID = payerChoices.first { $0.id == me }?.id ?? payerChoices.first?.id
    }

    private func add() {
        guard let saved = selectedGroup, let payerID else { return }
        var group = saved.group
        var idMapping: [Person.ID: Person.ID] = [:]
        for diner in diners {
            if let member = mapping[diner.id] ?? nil {
                idMapping[diner.id] = member
            } else {
                group.apply(.addMember(diner.withColorIndex(group.people.count)), by: Me.parse(meIDString))
                idMapping[diner.id] = diner.id
            }
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let expense = Expense.itemized(from: snapshot, title: cleanTitle.isEmpty ? "Receipt" : cleanTitle,
                                       payers: [payerID: 0], mapping: idMapping, currencyCode: group.currencyCode)
        group.apply(.addEntry(.expense(expense)), by: Me.parse(meIDString))
        saved.update(from: group)
        PeopleDirectory.register(diners, in: context)
        onAdded(saved, expense)
        dismiss()
    }
}
