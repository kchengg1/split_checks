import SwiftUI
import SettledCore

/// Everything about one expense: who paid, who owes what, notes, the
/// receipt photo, and repeats. Edits and deletes go through the group
/// binding so the parent persists them.
struct ExpenseDetailView: View {
    @Binding var group: ExpenseGroup
    let expenseID: UUID
    let meID: Person.ID?
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var receiptFlow: BillFlowModel?

    private var expense: Expense? {
        group.expenses.first { $0.id == expenseID }
    }

    private var namer: Namer { Namer(group: group, meID: meID) }

    var body: some View {
        Group {
            if let expense {
                content(expense)
            } else {
                ContentUnavailableView("This expense was deleted", systemImage: "trash",
                                       description: Text("Restore it from the group's activity."))
            }
        }
        .navigationTitle(expense?.title ?? "Expense")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                    .disabled(expense == nil)
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(expense == nil)
            }
        }
        .sheet(isPresented: $editing) {
            if let expense {
                ExpenseEditorView(group: group, existing: expense, meID: meID) { updated in
                    group.apply(.updateEntry(.expense(updated)), by: meID)
                }
            }
        }
        .fullScreenCover(item: $receiptFlow) { model in
            ReceiptFlowSheet(model: model)
        }
        .confirmationDialog("Delete this expense?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                group.apply(.deleteEntry(expenseID), by: meID)
                dismiss()
            }
        } message: {
            Text("You can restore it from the group's activity.")
        }
    }

    private func content(_ expense: Expense) -> some View {
        let known = Set(group.people.map(\.id))
        let contribution = SettlementEngine.contribution(for: expense, knownPeople: known)
        let owed = SettlementEngine.owedShares(for: expense, knownPeople: known)

        return List {
            header(expense)
                .cardRow()

            Section("Paid by") {
                ForEach(expense.payerIDs, id: \.self) { id in
                    personRow(id, cents: expense.paidCents(by: id), currencyCode: expense.currencyCode)
                }
            }

            Section {
                ForEach(group.people.filter { owed[$0.id] != nil }) { person in
                    personRow(person.id, cents: owed[person.id] ?? 0, currencyCode: expense.currencyCode)
                }
            } header: {
                Text("Split · \(splitTitle(expense.split))")
            } footer: {
                if let conversion = expense.conversion {
                    Text("Counted as \(Money.format(conversion.amountCents, currencyCode: conversion.currencyCode)) in balances; shares scale to match.")
                }
            }

            if let line = myLine(contribution) {
                Section {
                    HStack {
                        Text(line.label)
                        Spacer()
                        Text(line.amount)
                            .font(.amount)
                            .monospacedDigit()
                            .foregroundStyle(line.color)
                    }
                }
            }

            if let bill = expense.itemizedBill {
                ItemizedBreakdownSections(snapshot: bill, namer: namer)
                Section {
                    Button {
                        editReceipt(expense, bill: bill)
                    } label: {
                        Label("Edit receipt", systemImage: "doc.viewfinder")
                    }
                } footer: {
                    Text("Reopens the scanned items so you can fix a line or reassign a dish; the split updates to match.")
                }
            }

            if !expense.notes.isEmpty {
                Section("Notes") {
                    Text(expense.notes)
                }
            }

            if let id = expense.receiptImageID, let image = ReceiptImageStore.load(id) {
                Section("Receipt") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }

            if let rule = expense.recurrence {
                Section("Repeats") {
                    LabeledContent(rule.frequency.title, value: "next \(rule.nextDate.formatted(date: .abbreviated, time: .omitted))")
                }
            } else if let sourceID = expense.recurringSourceID,
                      let source = group.entry(withID: sourceID)?.expense {
                Section("Repeats") {
                    Text("Generated from \"\(source.title)\" (\(source.recurrence?.frequency.title.lowercased() ?? "recurring")).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
    }

    private func header(_ expense: Expense) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(systemImage: expense.category.systemImage, color: Theme.accent, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(expense.title)
                        .font(.cardTitle)
                    Text("\(expense.category.title) · \(expense.date.formatted(date: .long, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            Text(Money.format(expense.amountCents, currencyCode: expense.currencyCode))
                .font(.heroAmount)
                .monospacedDigit()
            if let conversion = expense.conversion {
                Text("≈ \(Money.format(conversion.amountCents, currencyCode: conversion.currencyCode))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func personRow(_ id: Person.ID, cents: Int, currencyCode: String) -> some View {
        HStack(spacing: 12) {
            if let person = group.person(withID: id) {
                Avatar(person: person, size: 32)
            }
            Text(namer.name(id))
            Spacer()
            Text(Money.format(cents, currencyCode: currencyCode))
                .font(.amount)
                .monospacedDigit()
        }
    }

    private func myLine(_ contribution: Contribution) -> (label: String, amount: String, color: Color)? {
        guard let meID else { return nil }
        let net = contribution.net[meID] ?? 0
        if net > 0 { return ("You lent", Money.format(net, currencyCode: contribution.currencyCode), Theme.positive) }
        if net < 0 { return ("You borrowed", Money.format(-net, currencyCode: contribution.currencyCode), Theme.negative) }
        return nil
    }

    /// Reopens the receipt flow on this expense's bill; saving regenerates
    /// the split and updates the expense in place.
    private func editReceipt(_ expense: Expense, bill: BillSnapshot) {
        let model = BillFlowModel()
        model.load(snapshot: bill, merchantName: expense.title)
        model.payerID = expense.payerID
        model.target = BillFlowModel.GroupTarget(groupID: group.id, groupName: group.name,
                                                 currencyCode: expense.currencyCode, existingExpense: expense)
        model.onItemized = { updated in
            for person in updated.itemizedBill?.people ?? [] where group.person(withID: person.id) == nil {
                group.apply(.addMember(person.withColorIndex(group.people.count)), by: meID)
            }
            group.apply(.updateEntry(.expense(updated)), by: meID)
            receiptFlow = nil
        }
        receiptFlow = model
    }

    private func splitTitle(_ split: SplitMethod) -> String {
        switch split {
        case .equally: return "equally"
        case .shares: return "by shares"
        case .percentages: return "by percent"
        case .exactCents: return "exact amounts"
        case .adjustment: return "with adjustments"
        }
    }
}

/// Per-person items from a scanned bill, the way the receipt summary
/// shows them. One section per person with a share.
struct ItemizedBreakdownSections: View {
    let snapshot: BillSnapshot
    let namer: Namer

    var body: some View {
        let result = snapshot.result
        ForEach(result.shares) { share in
            if share.totalCents != 0, let person = snapshot.people.first(where: { $0.id == share.personID }) {
                Section {
                    ForEach(snapshot.items) { item in
                        if let cents = result.itemBreakdown[item.id]?[person.id] {
                            row(cents == item.priceCents ? item.name : "\(item.name) (shared)", cents)
                        }
                    }
                    if share.taxCents != 0 { row("Tax", share.taxCents) }
                    if share.tipCents != 0 { row("Tip", share.tipCents) }
                } header: {
                    HStack {
                        Text(namer.isMe(person.id) ? "Your items" : "\(person.name)'s items")
                        Spacer()
                        Text(Money.format(share.totalCents))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ cents: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(Money.format(cents))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
