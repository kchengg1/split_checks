import SwiftUI
import SplitChecksCore

/// Record a trip expense: who paid, how much, and how it's split.
struct AddExpenseView: View {
    let trip: Trip
    let onAdd: (Expense) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var amountCents = 0
    @State private var payerID: Person.ID
    @State private var date = Date.now
    @State private var mode: SplitMode = .equally
    @State private var selected: Set<Person.ID>
    @State private var weights: [Person.ID: Int]
    @State private var exact: [Person.ID: Int]

    enum SplitMode: String, CaseIterable {
        case equally = "Equally"
        case shares = "Shares"
        case exact = "Exact"
    }

    init(trip: Trip, onAdd: @escaping (Expense) -> Void) {
        self.trip = trip
        self.onAdd = onAdd
        _payerID = State(initialValue: trip.people.first?.id ?? UUID())
        _selected = State(initialValue: Set(trip.people.map(\.id)))
        _weights = State(initialValue: Dictionary(uniqueKeysWithValues: trip.people.map { ($0.id, 1) }))
        _exact = State(initialValue: [:])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What for?", text: $title)
                    HStack {
                        Text("Amount")
                        Spacer()
                        CurrencyField(title: "0.00", cents: $amountCents).frame(width: 110)
                    }
                    Picker("Paid by", selection: $payerID) {
                        ForEach(trip.people) { Text($0.name).tag($0.id) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Split") {
                    Picker("Split", selection: $mode) {
                        ForEach(SplitMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    ForEach(trip.people) { person in
                        splitRow(person)
                    }

                    if let hint = remainingHint {
                        Text(hint).font(.footnote).foregroundStyle(hintIsError ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("New expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!isValid)
                }
            }
        }
    }

    @ViewBuilder
    private func splitRow(_ person: Person) -> some View {
        switch mode {
        case .equally:
            Button {
                if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
            } label: {
                HStack {
                    Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(person.id) ? ChipPalette.color(for: person) : .secondary)
                    Text(person.name).foregroundStyle(.primary)
                    Spacer()
                    if selected.contains(person.id), !selected.isEmpty {
                        Text(Money.format(equalShare(for: person), currencyCode: trip.currencyCode))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        case .shares:
            Stepper(value: Binding(get: { weights[person.id] ?? 0 }, set: { weights[person.id] = max(0, $0) }), in: 0...99) {
                HStack {
                    Text(person.name)
                    Spacer()
                    Text("\(weights[person.id] ?? 0)×").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .exact:
            HStack {
                Text(person.name)
                Spacer()
                CurrencyField(title: "0.00", cents: Binding(get: { exact[person.id] ?? 0 }, set: { exact[person.id] = $0 }))
                    .frame(width: 100)
            }
        }
    }

    private func equalShare(for person: Person) -> Int {
        let ids = trip.people.map(\.id).filter { selected.contains($0) }
        guard let index = ids.firstIndex(of: person.id) else { return 0 }
        return SplitEngine.apportion(amountCents, weights: Array(repeating: 1, count: ids.count))[index]
    }

    // MARK: - Validation

    private var exactSum: Int { trip.people.reduce(0) { $0 + (exact[$1.id] ?? 0) } }
    private var weightSum: Int { weights.values.reduce(0, +) }

    private var isValid: Bool {
        guard amountCents != 0, trip.people.contains(where: { $0.id == payerID }) else { return false }
        switch mode {
        case .equally: return !selected.isEmpty
        case .shares: return weightSum > 0
        case .exact: return exactSum == amountCents
        }
    }

    private var remainingHint: String? {
        switch mode {
        case .equally:
            return selected.isEmpty ? "Select at least one person." : nil
        case .shares:
            return weightSum == 0 ? "Give at least one person a share." : nil
        case .exact:
            let diff = amountCents - exactSum
            if diff == 0 { return nil }
            let word = diff > 0 ? "left to assign" : "over"
            return "\(Money.format(abs(diff), currencyCode: trip.currencyCode)) \(word)."
        }
    }

    private var hintIsError: Bool {
        switch mode {
        case .exact: return exactSum != amountCents
        default: return true
        }
    }

    private func add() {
        let split: SplitMethod
        switch mode {
        case .equally:
            let ids = trip.people.map(\.id).filter { selected.contains($0) }
            split = .equally(participantIDs: ids)
        case .shares:
            split = .shares(weights.filter { $0.value > 0 })
        case .exact:
            split = .exactCents(exact.filter { $0.value != 0 })
        }
        let expense = Expense(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? "Expense" : title,
            payerID: payerID,
            amountCents: amountCents,
            date: date,
            split: split
        )
        onAdd(expense)
        dismiss()
    }
}
