import SwiftUI
import PhotosUI
import SettledCore

/// Add or edit a group expense: what, how much and in which currency, who
/// paid (one or several), how it's split, plus category, notes, a receipt
/// photo, and repeats. Editing keeps the expense's identity so the activity
/// trail and balances line up. Validation comes from the core package and
/// shows inline.
struct ExpenseEditorView: View {
    let group: ExpenseGroup
    let existing: Expense?
    let meID: Person.ID?
    let onSave: (Expense) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var amountCents: Int
    @State private var currencyCode: String
    @State private var date: Date
    @State private var category: ExpenseCategory
    @State private var notes: String

    @State private var multiplePayers: Bool
    @State private var singlePayerID: Person.ID
    @State private var payerAmounts: [Person.ID: Int]

    @State private var mode: SplitMode
    @State private var selected: Set<Person.ID>
    @State private var weights: [Person.ID: Int]
    @State private var exact: [Person.ID: Int]
    @State private var adjustments: [Person.ID: Int]

    @State private var conversionCents: Int
    @State private var frequency: RecurrenceRule.Frequency?
    @State private var receiptImageID: UUID?
    @State private var receiptImage: UIImage?
    @State private var receiptChanged = false
    @State private var photoItem: PhotosPickerItem?

    enum SplitMode: String, CaseIterable {
        case equally = "Equally"
        case shares = "Shares"
        case exact = "Exact"
        case adjust = "Adjust"
    }

    init(group: ExpenseGroup, existing: Expense?, meID: Person.ID?, onSave: @escaping (Expense) -> Void) {
        self.group = group
        self.existing = existing
        self.meID = meID
        self.onSave = onSave

        let everyone = group.people.map(\.id)
        let defaultPayer = meID.flatMap { id in everyone.contains(id) ? id : nil } ?? everyone.first ?? UUID()
        _title = State(initialValue: existing?.title ?? "")
        _amountCents = State(initialValue: existing?.amountCents ?? 0)
        _currencyCode = State(initialValue: existing.map { $0.currencyCode.isEmpty ? group.currencyCode : $0.currencyCode } ?? group.currencyCode)
        _date = State(initialValue: existing?.date ?? .now)
        _category = State(initialValue: existing?.category ?? .general)
        _notes = State(initialValue: existing?.notes ?? "")

        _multiplePayers = State(initialValue: existing?.isMultiPayer ?? false)
        _singlePayerID = State(initialValue: existing?.payerID ?? defaultPayer)
        _payerAmounts = State(initialValue: existing?.payers ?? [:])

        var mode: SplitMode = .equally
        var selected = Set(everyone)
        var weights = Dictionary(uniqueKeysWithValues: everyone.map { ($0, 1) })
        var exact: [Person.ID: Int] = [:]
        var adjustments: [Person.ID: Int] = [:]
        if let existing {
            switch existing.split {
            case .equally(let ids):
                selected = Set(ids)
            case .shares(let map), .percentages(let map):
                // Basis points are just weights, so percentages edit as shares.
                mode = .shares
                weights = Dictionary(uniqueKeysWithValues: everyone.map { ($0, map[$0] ?? 0) })
            case .exactCents(let map):
                mode = .exact
                exact = map
            case .adjustment(let ids, let map):
                mode = .adjust
                selected = Set(ids)
                adjustments = map
            }
        }
        _mode = State(initialValue: mode)
        _selected = State(initialValue: selected)
        _weights = State(initialValue: weights)
        _exact = State(initialValue: exact)
        _adjustments = State(initialValue: adjustments)

        _conversionCents = State(initialValue: existing?.conversion?.amountCents ?? 0)
        _frequency = State(initialValue: existing?.recurrence?.frequency)
        _receiptImageID = State(initialValue: existing?.receiptImageID)
        _receiptImage = State(initialValue: existing?.receiptImageID.flatMap(ReceiptImageStore.load))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                paidBySection
                if existing?.isItemized == true {
                    itemizedSection
                } else {
                    splitSection
                }
                if currencyCode != group.currencyCode {
                    conversionSection
                }
                detailsSection
                receiptSection
                repeatsSection
            }
            .navigationTitle(existing == nil ? "New expense" : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") { save() }.disabled(!errors.isEmpty)
                }
            }
            .onChange(of: photoItem) { loadPhoto() }
        }
    }

    private var basicsSection: some View {
        Section {
            HStack(spacing: 12) {
                IconBadge(systemImage: category.systemImage, color: Theme.accent, size: 36)
                TextField("What for?", text: $title)
                    .font(.cardTitle)
            }
            HStack {
                Text("Amount")
                Spacer()
                Text(currencyCode)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if existing?.isItemized == true {
                    Text(Money.format(amountCents, currencyCode: currencyCode))
                        .font(.amount)
                        .monospacedDigit()
                } else {
                    CurrencyField(title: "0.00", cents: $amountCents).frame(width: 110)
                }
            }
            Picker("Currency", selection: $currencyCode) {
                ForEach(Currencies.options(including: currencyCode), id: \.self) { code in
                    Text("\(code) · \(Currencies.name(code))").tag(code)
                }
            }
            Picker("Category", selection: $category) {
                ForEach(ExpenseCategory.allCases, id: \.self) { category in
                    Label(category.title, systemImage: category.systemImage).tag(category)
                }
            }
            DatePicker("Date", selection: $date, displayedComponents: .date)
        }
    }

    private var paidBySection: some View {
        Section {
            if multiplePayers {
                ForEach(group.people) { person in
                    HStack {
                        Avatar(person: person, size: 28)
                        Text(name(person))
                        Spacer()
                        CurrencyField(title: "0.00", cents: Binding(
                            get: { payerAmounts[person.id] ?? 0 },
                            set: { payerAmounts[person.id] = $0 }
                        ))
                        .frame(width: 100)
                    }
                }
            } else {
                Picker("Paid by", selection: $singlePayerID) {
                    ForEach(group.people) { Text(name($0)).tag($0.id) }
                }
            }
            Toggle("Multiple people paid", isOn: $multiplePayers)
        } header: {
            Text("Paid by")
        } footer: {
            if multiplePayers, let hint = payersHint {
                Text(hint).foregroundStyle(.red)
            }
        }
    }

    private var splitSection: some View {
        Section {
            Picker("Split", selection: $mode) {
                ForEach(SplitMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            ForEach(group.people) { person in
                splitRow(person)
            }
        } header: {
            Text("Split")
        } footer: {
            if let hint = splitHint {
                Text(hint).foregroundStyle(splitHintIsError ? .red : .secondary)
            } else if mode == .adjust {
                Text("Everyone splits what's left equally after their adjustments.")
            }
        }
    }

    private var itemizedSection: some View {
        Section {
            Label("Split comes from the scanned receipt", systemImage: "doc.viewfinder")
                .foregroundStyle(.secondary)
        } header: {
            Text("Split")
        } footer: {
            Text("Each person owes exactly their items plus tax and tip. To change it, open the expense and edit the receipt.")
        }
    }

    private var conversionSection: some View {
        Section {
            HStack {
                Text("Counts as")
                Spacer()
                Text(group.currencyCode)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                CurrencyField(title: "0.00", cents: $conversionCents).frame(width: 110)
            }
        } header: {
            Text("Conversion")
        } footer: {
            Text(conversionCents > 0
                 ? "Balances will count this expense as \(Money.format(conversionCents, currencyCode: group.currencyCode))."
                 : "Optional. Leave empty to keep a separate \(currencyCode) balance for the group.")
        }
    }

    private var detailsSection: some View {
        Section("Notes") {
            TextField("Anything worth remembering", text: $notes, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private var receiptSection: some View {
        Section {
            if let receiptImage {
                Image(uiImage: receiptImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                Button(role: .destructive) {
                    self.receiptImage = nil
                    receiptChanged = true
                } label: {
                    Label("Remove photo", systemImage: "trash")
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(receiptImage == nil ? "Attach a receipt photo" : "Replace photo", systemImage: "photo")
            }
        } header: {
            Text("Receipt")
        } footer: {
            Text("Stored on this phone only.")
        }
    }

    private var repeatsSection: some View {
        Section {
            Picker("Repeats", selection: $frequency) {
                Text("Never").tag(RecurrenceRule.Frequency?.none)
                ForEach(RecurrenceRule.Frequency.allCases, id: \.self) { f in
                    Text(f.title).tag(RecurrenceRule.Frequency?.some(f))
                }
            }
        } footer: {
            if let frequency {
                let next = existing?.recurrence?.nextDate ?? RecurrenceRule.firstNextDate(after: date, frequency: frequency)
                Text("Next on \(next.formatted(date: .abbreviated, time: .omitted)). Copies are added when you open the app.")
            }
        }
    }

    // MARK: - Rows

    private func name(_ person: Person) -> String {
        person.id == meID ? "You" : person.name
    }

    @ViewBuilder
    private func splitRow(_ person: Person) -> some View {
        switch mode {
        case .equally, .adjust:
            HStack {
                Button {
                    if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(person.id) ? ChipPalette.color(for: person) : .secondary)
                        Text(name(person)).foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                if mode == .adjust {
                    if selected.contains(person.id) {
                        Text("±")
                            .foregroundStyle(.secondary)
                        CurrencyField(title: "0.00", cents: Binding(
                            get: { adjustments[person.id] ?? 0 },
                            set: { adjustments[person.id] = $0 }
                        ))
                        .frame(width: 90)
                    }
                } else if selected.contains(person.id), !selected.isEmpty {
                    Text(Money.format(equalShare(for: person), currencyCode: currencyCode))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        case .shares:
            Stepper(value: Binding(get: { weights[person.id] ?? 0 }, set: { weights[person.id] = max(0, $0) }), in: 0...99) {
                HStack {
                    Text(name(person))
                    Spacer()
                    Text("\(weights[person.id] ?? 0)×").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .exact:
            HStack {
                Text(name(person))
                Spacer()
                CurrencyField(title: "0.00", cents: Binding(get: { exact[person.id] ?? 0 }, set: { exact[person.id] = $0 }))
                    .frame(width: 100)
            }
        }
    }

    private func equalShare(for person: Person) -> Int {
        let ids = group.people.map(\.id).filter { selected.contains($0) }
        guard let index = ids.firstIndex(of: person.id) else { return 0 }
        return SplitEngine.apportion(amountCents, weights: Array(repeating: 1, count: ids.count))[index]
    }

    // MARK: - Draft & validation

    private var payers: [Person.ID: Int] {
        if multiplePayers {
            return payerAmounts.filter { $0.value != 0 }
        }
        return [singlePayerID: amountCents]
    }

    private var split: SplitMethod {
        if let existing, existing.isItemized { return existing.split }
        let ids = group.people.map(\.id).filter { selected.contains($0) }
        switch mode {
        case .equally: return .equally(participantIDs: ids)
        case .shares: return .shares(weights.filter { $0.value > 0 })
        case .exact: return .exactCents(exact.filter { $0.value != 0 })
        case .adjust: return .adjustment(participantIDs: ids, adjustments: adjustments.filter { ids.contains($0.key) && $0.value != 0 })
        }
    }

    private var draft: Expense {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let conversion = currencyCode != group.currencyCode && conversionCents != 0
            ? ConvertedAmount(currencyCode: group.currencyCode, amountCents: conversionCents) : nil
        let recurrence: RecurrenceRule? = frequency.map { (f: RecurrenceRule.Frequency) -> RecurrenceRule in
            if let old = existing?.recurrence, old.frequency == f { return old }
            return RecurrenceRule(frequency: f, nextDate: RecurrenceRule.firstNextDate(after: date, frequency: f))
        }
        return Expense(
            id: existing?.id ?? UUID(),
            title: cleanTitle,
            payers: payers,
            amountCents: amountCents,
            currencyCode: currencyCode,
            date: date,
            split: split,
            category: category,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            receiptImageID: receiptImageID,
            itemizedBill: existing?.itemizedBill,
            conversion: conversion,
            recurrence: recurrence,
            recurringSourceID: existing?.recurringSourceID,
            createdAt: existing?.createdAt ?? .now,
            updatedAt: .now
        )
    }

    private var errors: [ExpenseValidationError] {
        ExpenseValidator.validate(draft, in: group)
    }

    private var payersHint: String? {
        for error in errors {
            if case .payersDoNotSumToAmount(let diff) = error {
                if diff > 0 { return "\(Money.format(diff, currencyCode: currencyCode)) left to cover." }
                return "\(Money.format(-diff, currencyCode: currencyCode)) more than the amount."
            }
        }
        return nil
    }

    private var splitHint: String? {
        for error in errors {
            switch error {
            case .noParticipants: return "Select at least one person."
            case .noPositiveWeights: return "Give at least one person a share."
            case .exactSharesDoNotSumToAmount(let diff):
                return "\(Money.format(abs(diff), currencyCode: currencyCode)) \(diff > 0 ? "left to assign" : "over")."
            case .adjustmentsExceedAmount(let by):
                return "Adjustments exceed the amount by \(Money.format(by, currencyCode: currencyCode))."
            default: continue
            }
        }
        return nil
    }

    private var splitHintIsError: Bool { splitHint != nil }

    // MARK: - Actions

    private func loadPhoto() {
        guard let photoItem else { return }
        self.photoItem = nil
        Task { @MainActor in
            if let data = try? await photoItem.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                receiptImage = image
                receiptChanged = true
            }
        }
    }

    private func save() {
        var expense = draft
        if receiptChanged {
            if let old = receiptImageID { ReceiptImageStore.delete(old) }
            expense.receiptImageID = receiptImage.flatMap(ReceiptImageStore.save)
        }
        onSave(expense)
        dismiss()
    }
}
