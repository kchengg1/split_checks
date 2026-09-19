import SwiftUI
import SettledCore

/// Record that someone paid someone back — in full or in part, by any
/// method. The app never moves money; recording means "the user said so".
struct RecordPaymentView: View {
    let group: ExpenseGroup
    let draft: PaymentDraft
    let meID: Person.ID?
    let onSave: (Payment) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var fromID: Person.ID
    @State private var toID: Person.ID
    @State private var cents: Int
    @State private var date: Date
    @State private var method: PaymentMethod
    @State private var note: String
    private let currencyCode: String

    init(group: ExpenseGroup, draft: PaymentDraft, meID: Person.ID?, onSave: @escaping (Payment) -> Void) {
        self.group = group
        self.draft = draft
        self.meID = meID
        self.onSave = onSave
        let ids = group.people.map(\.id)
        let defaultFrom = draft.fromID ?? meID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first ?? UUID()
        let defaultTo = draft.toID ?? ids.first { $0 != defaultFrom } ?? ids.first ?? UUID()
        _fromID = State(initialValue: defaultFrom)
        _toID = State(initialValue: defaultTo)
        _cents = State(initialValue: draft.cents)
        _date = State(initialValue: draft.existing?.date ?? .now)
        _method = State(initialValue: draft.existing?.method ?? .cash)
        _note = State(initialValue: draft.existing?.note ?? "")
        currencyCode = draft.currencyCode ?? group.currencyCode
    }

    private var isValid: Bool {
        cents > 0 && fromID != toID
            && group.person(withID: fromID) != nil && group.person(withID: toID) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("From", selection: $fromID) {
                        ForEach(group.people) { Text(name($0)).tag($0.id) }
                    }
                    Picker("To", selection: $toID) {
                        ForEach(group.people) { Text(name($0)).tag($0.id) }
                    }
                    HStack {
                        Text("Amount")
                        Spacer()
                        Text(currencyCode)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        CurrencyField(title: "0.00", cents: $cents).frame(width: 110)
                    }
                } footer: {
                    if fromID == toID {
                        Text("Pick two different people.").foregroundStyle(.red)
                    } else if let suggested = suggestedCents, suggested != cents {
                        Text("\(name(for: fromID)) currently owes \(name(for: toID)) \(Money.format(suggested, currencyCode: currencyCode)).")
                    }
                }

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Note (optional)", text: $note)
                }

                if !handoffOptions.isEmpty {
                    Section {
                        ForEach(handoffOptions) { option in
                            Button {
                                method = option.method
                                openURL(option.url)
                            } label: {
                                Label(option.title, systemImage: option.systemImage)
                            }
                        }
                    } footer: {
                        Text("Opens the app prefilled. Come back and tap Record once it's sent.")
                    }
                }
            }
            .navigationTitle(draft.existing == nil ? "Record payment" : "Edit payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.existing == nil ? "Record" : "Save") { save() }.disabled(!isValid)
                }
            }
        }
    }

    /// Pay-with links when I'm the one paying and the payee has a handle.
    private var handoffOptions: [PaymentHandoff.Option] {
        guard fromID == meID, let payee = group.person(withID: toID) else { return [] }
        return PaymentHandoff.options(for: payee.handles, cents: cents > 0 ? cents : nil,
                                      currencyCode: currencyCode, note: group.name)
    }

    /// What the pairwise ledger says `from` owes `to` right now, if anything.
    private var suggestedCents: Int? {
        SettlementEngine.pairwiseDebts(for: group, currencyCode: currencyCode)
            .first { $0.fromID == fromID && $0.toID == toID }?.cents
    }

    private func name(_ person: Person) -> String {
        person.id == meID ? "You" : person.name
    }

    private func name(for id: Person.ID) -> String {
        id == meID ? "You" : group.name(of: id)
    }

    private func save() {
        let payment = Payment(
            id: draft.existing?.id ?? UUID(),
            fromID: fromID,
            toID: toID,
            cents: cents,
            currencyCode: currencyCode,
            date: date,
            method: method,
            note: note.trimmingCharacters(in: .whitespaces),
            createdAt: draft.existing?.createdAt ?? .now,
            updatedAt: .now
        )
        onSave(payment)
        dismiss()
    }
}
