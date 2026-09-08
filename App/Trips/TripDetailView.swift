import SwiftUI
import SwiftData
import SplitChecksCore

/// One trip: browse and add expenses, manage people, and see balances with a
/// minimized "settle up". Edits mutate a local `Trip` value and persist back
/// to the `SavedTrip` on every change.
struct TripDetailView: View {
    let saved: SavedTrip
    @State private var trip: Trip
    @State private var mode: Mode = .expenses
    @State private var showingAddExpense = false
    @State private var newPersonName = ""
    @FocusState private var personFieldFocused: Bool

    enum Mode: String, CaseIterable {
        case expenses = "Expenses"
        case balances = "Balances"
        case people = "People"
    }

    init(saved: SavedTrip) {
        self.saved = saved
        _trip = State(initialValue: saved.trip)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .expenses: expensesList
            case .balances: balancesList
            case .people: peopleList
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .expenses {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddExpense = true } label: { Label("Add expense", systemImage: "plus") }
                        .disabled(trip.people.isEmpty)
                }
            }
            if mode == .balances {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: settlementText) { Label("Share", systemImage: "square.and.arrow.up") }
                        .disabled(trip.expenses.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView(trip: trip) { expense in
                trip.expenses.insert(expense, at: 0)
            }
        }
        // Any mutation of `trip` is written straight back to storage.
        .onChange(of: trip) { saved.update(from: trip) }
    }

    // MARK: - Expenses

    @ViewBuilder
    private var expensesList: some View {
        if trip.people.isEmpty {
            ContentUnavailableView {
                Label("Add people first", systemImage: "person.2")
            } description: {
                Text("Switch to the People tab to add who's on this trip, then record expenses.")
            }
        } else if trip.expenses.isEmpty {
            ContentUnavailableView {
                Label("No expenses yet", systemImage: "creditcard")
            } description: {
                Text("Tap + to add what someone paid for.")
            }
        } else {
            List {
                ForEach(trip.expenses) { expense in
                    expenseRow(expense)
                }
                .onDelete { offsets in
                    trip.expenses.remove(atOffsets: offsets)
                }
                Section {
                    HStack {
                        Text("Total").fontWeight(.semibold)
                        Spacer()
                        Text(Money.format(trip.totalCents, currencyCode: trip.currencyCode))
                            .monospacedDigit().fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func expenseRow(_ expense: Expense) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title)
                Text("Paid by \(name(expense.payerID)) · \(splitSummary(expense))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.format(expense.amountCents, currencyCode: trip.currencyCode))
                .monospacedDigit()
                .foregroundStyle(expense.amountCents < 0 ? .green : .primary)
        }
    }

    // MARK: - Balances & settle up

    private var balancesList: some View {
        let settlement = SettlementEngine.settlement(for: trip)
        return List {
            Section("Balances") {
                if trip.expenses.isEmpty {
                    Text("No expenses yet.").foregroundStyle(Color.secondary)
                }
                ForEach(settlement.balances) { balance in
                    balanceRow(balance)
                }
            }

            Section("Settle up") {
                if settlement.transfers.isEmpty {
                    settledUpLabel
                } else {
                    ForEach(settlement.transfers.indices, id: \.self) { index in
                        transferRow(settlement.transfers[index])
                    }
                }
            }
        }
    }

    private func balanceRow(_ balance: Balance) -> some View {
        HStack {
            if let person = trip.people.first(where: { $0.id == balance.personID }) {
                PersonChip(person: person)
            }
            Spacer()
            Text(balanceLabel(balance.cents))
                .monospacedDigit()
                .foregroundStyle(balanceColor(balance.cents))
        }
    }

    private func transferRow(_ transfer: Transfer) -> some View {
        HStack {
            Text(name(transfer.fromID))
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(Color.secondary)
            Text(name(transfer.toID))
            Spacer()
            Text(Money.format(transfer.cents, currencyCode: trip.currencyCode))
                .monospacedDigit().fontWeight(.medium)
        }
    }

    private var settledUpLabel: some View {
        let empty = trip.expenses.isEmpty
        return Label(empty ? "Nothing to settle yet" : "All settled up 🎉",
                     systemImage: empty ? "tray" : "checkmark.seal.fill")
            .foregroundStyle(empty ? Color.secondary : Color.green)
    }

    private func balanceColor(_ cents: Int) -> Color {
        if cents == 0 { return .secondary }
        return cents > 0 ? .green : .red
    }

    private func balanceLabel(_ cents: Int) -> String {
        if cents == 0 { return "settled" }
        let amount = Money.format(abs(cents), currencyCode: trip.currencyCode)
        return cents > 0 ? "gets back \(amount)" : "owes \(amount)"
    }

    // MARK: - People

    private var peopleList: some View {
        List {
            Section {
                ForEach(trip.people) { person in
                    HStack {
                        PersonChip(person: person)
                        Spacer()
                        if isReferenced(person) {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    // Only remove people not tied to any expense, so balances
                    // stay consistent.
                    let removable = offsets.filter { !isReferenced(trip.people[$0]) }
                    trip.people.remove(atOffsets: IndexSet(removable))
                }
            } footer: {
                Text("People in an expense can't be removed. A locked icon marks them.")
            }

            Section {
                HStack {
                    TextField("Add person", text: $newPersonName)
                        .focused($personFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(addPerson)
                    Button(action: addPerson) { Image(systemName: "plus.circle.fill").font(.title2) }
                        .disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Add person")
                }
            }
        }
    }

    private func addPerson() {
        let trimmed = newPersonName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        trip.people.append(Person(name: trimmed, colorIndex: trip.people.count))
        newPersonName = ""
        personFieldFocused = true
    }

    // MARK: - Helpers

    private func name(_ id: Person.ID) -> String {
        trip.people.first { $0.id == id }?.name ?? "?"
    }

    private func isReferenced(_ person: Person) -> Bool {
        trip.expenses.contains { expense in
            if expense.payerID == person.id { return true }
            switch expense.split {
            case .equally(let ids): return ids.contains(person.id)
            case .shares(let w): return w[person.id] != nil
            case .percentages(let p): return p[person.id] != nil
            case .exactCents(let c): return c[person.id] != nil
            }
        }
    }

    private func splitSummary(_ expense: Expense) -> String {
        switch expense.split {
        case .equally(let ids): return "split \(ids.count) ways"
        case .shares: return "by shares"
        case .percentages: return "by percent"
        case .exactCents: return "exact amounts"
        }
    }

    private var settlementText: String {
        let settlement = SettlementEngine.settlement(for: trip)
        var lines = ["✈️ \(trip.name) — settle up"]
        if settlement.transfers.isEmpty {
            lines.append("All settled up.")
        } else {
            for transfer in settlement.transfers {
                lines.append("\(name(transfer.fromID)) → \(name(transfer.toID)): \(Money.format(transfer.cents, currencyCode: trip.currencyCode))")
            }
        }
        lines.append("")
        lines.append("Total \(Money.format(trip.totalCents, currencyCode: trip.currencyCode))")
        return lines.joined(separator: "\n")
    }
}
