import SwiftUI
import SwiftData
import SettledCore

/// One friend: the net per currency, which groups it comes from, and the
/// ways to settle — record everything at once, hand off to a payment app,
/// or set a reminder.
struct FriendDetailView: View {
    let friendID: Person.ID
    @Query(sort: \SavedTrip.updatedAt, order: .reverse) private var savedGroups: [SavedTrip]
    @Query private var people: [SavedPerson]
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @Environment(\.openURL) private var openURL
    @State private var showingSettleAll = false
    @State private var showingReminderPicker = false
    @State private var reminderDate = Reminders.morning(daysFromNow: 1)
    @State private var reminderResult: String?

    private var meID: Person.ID? { Me.parse(meIDString) }
    private var directoryPerson: SavedPerson? { people.first { $0.id == friendID } }

    private var friend: FriendBalance? {
        guard let meID else { return nil }
        return FriendLedger.balances(groups: savedGroups.map(\.group), meID: meID).first { $0.personID == friendID }
    }

    private var person: Person {
        directoryPerson?.person ?? Person(id: friendID, name: friend?.name ?? "?", colorIndex: 0)
    }

    var body: some View {
        Group {
            if let friend {
                content(friend)
            } else {
                ContentUnavailableView("No shared groups", systemImage: "person.2",
                                       description: Text("You don't share a group with this person yet."))
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSettleAll) {
            if let meID {
                SettleAllSheet(friend: person, meID: meID, savedGroups: savedGroups)
            }
        }
        .sheet(isPresented: $showingReminderPicker) {
            reminderPicker
        }
        .alert("Reminder", isPresented: Binding(get: { reminderResult != nil }, set: { if !$0 { reminderResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reminderResult ?? "")
        }
    }

    private func content(_ friend: FriendBalance) -> some View {
        List {
            header(friend)
                .cardRow()

            if !friend.groups.isEmpty {
                Section("By group") {
                    ForEach(Array(friend.groups.enumerated()), id: \.offset) { _, g in
                        NavigationLink(value: GroupRoute(id: g.groupID)) {
                            HStack {
                                if let saved = savedGroups.first(where: { $0.id == g.groupID }) {
                                    KindBadge(kind: saved.kind, size: 32)
                                }
                                Text(g.groupName)
                                Spacer()
                                Text(FriendWording.pill(cents: g.cents, currencyCode: g.currencyCode))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.balanceColor(g.cents))
                            }
                        }
                    }
                }
            }

            if !friend.isSettled {
                Section {
                    Button {
                        showingSettleAll = true
                    } label: {
                        Label("Settle up everything", systemImage: "checkmark.circle")
                    }
                    ForEach(handoffOptions(friend)) { option in
                        Button {
                            openURL(option.url)
                        } label: {
                            Label(option.title, systemImage: option.systemImage)
                        }
                    }
                } header: {
                    Text("Settle up")
                } footer: {
                    if handoffOptions(friend).isEmpty, iOwe(friend) {
                        Text("Add \(person.name)'s Venmo, PayPal, or Cash App in Settings › People to pay from here.")
                    } else if !handoffOptions(friend).isEmpty {
                        Text("Opens the app prefilled. Come back and record the payment once it's sent.")
                    }
                }

                Section {
                    Menu {
                        Button("Tomorrow morning") { remind(at: Reminders.morning(daysFromNow: 1), friend: friend) }
                        Button("In a week") { remind(at: Reminders.morning(daysFromNow: 7), friend: friend) }
                        Button("Pick a date…") { showingReminderPicker = true }
                    } label: {
                        Label("Remind me", systemImage: "bell")
                    }
                } footer: {
                    Text("A notification on this phone only.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
    }

    private func header(_ friend: FriendBalance) -> some View {
        Card {
            HStack(spacing: 14) {
                Avatar(person: person, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.name).font(.cardTitle)
                    if friend.isSettled {
                        Text("All settled up").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(friend.byCurrency.keys.sorted(), id: \.self) { code in
                            let cents = friend.byCurrency[code] ?? 0
                            Text(FriendWording.pill(cents: cents, currencyCode: code))
                                .font(.bigAmount)
                                .monospacedDigit()
                                .foregroundStyle(Theme.balanceColor(cents))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Actions

    private func iOwe(_ friend: FriendBalance) -> Bool {
        friend.byCurrency.values.contains { $0 < 0 }
    }

    /// Pay-with buttons when I owe them and they have a handle. The amount
    /// is prefilled only when there's a single currency to settle.
    private func handoffOptions(_ friend: FriendBalance) -> [PaymentHandoff.Option] {
        guard iOwe(friend) else { return [] }
        let owed = friend.byCurrency.filter { $0.value < 0 }
        let single = owed.count == 1 ? owed.first : nil
        return PaymentHandoff.options(for: person.handles,
                                      cents: single.map { -$0.value },
                                      currencyCode: single?.key ?? "USD",
                                      note: "Settle up")
    }

    private func remind(at date: Date, friend: FriendBalance) {
        let summary = friend.byCurrency.keys.sorted()
            .map { FriendWording.pill(cents: friend.byCurrency[$0] ?? 0, currencyCode: $0) }
            .joined(separator: ", ")
        Task { @MainActor in
            let ok = await Reminders.schedule(id: "settle-\(friendID.uuidString)",
                                              title: "Settle up with \(person.name)",
                                              body: summary.prefix(1).uppercased() + String(summary.dropFirst()),
                                              at: date)
            reminderResult = ok
                ? "You'll be reminded on \(date.formatted(date: .abbreviated, time: .shortened))."
                : "Notifications are off for Settled. Turn them on in Settings to get reminders."
        }
    }

    private var reminderPicker: some View {
        NavigationStack {
            Form {
                DatePicker("Remind me", selection: $reminderDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
            }
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingReminderPicker = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        showingReminderPicker = false
                        if let friend { remind(at: reminderDate, friend: friend) }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Records one payment per group and currency so a friend is settled
/// everywhere at once.
struct SettleAllSheet: View {
    let friend: Person
    let meID: Person.ID
    let savedGroups: [SavedTrip]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var method: PaymentMethod = .cash
    @State private var date = Date.now

    private var payments: [(groupID: UUID, payment: Payment)] {
        FriendLedger.settleUpPayments(with: friend.id, groups: savedGroups.map(\.group), meID: meID, date: date, method: method)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(payments.enumerated()), id: \.offset) { _, item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.payment.fromID == meID ? "You pay \(friend.name)" : "\(friend.name) pays you")
                                Text(savedGroups.first { $0.id == item.groupID }?.name ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Money.format(item.payment.cents, currencyCode: item.payment.currencyCode))
                                .font(.amount)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Payments to record")
                } footer: {
                    Text("Each is recorded in its group, so every balance with \(friend.name) goes to zero.")
                }
                Section {
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle("Settle up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record all") { recordAll() }.disabled(payments.isEmpty)
                }
            }
        }
    }

    private func recordAll() {
        for (groupID, payment) in payments {
            guard let saved = savedGroups.first(where: { $0.id == groupID }) else { continue }
            var group = saved.group
            group.apply(.addEntry(.payment(payment)), by: meID)
            saved.update(from: group)
        }
        dismiss()
    }
}
