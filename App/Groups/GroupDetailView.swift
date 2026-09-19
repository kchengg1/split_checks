import SwiftUI
import SwiftData
import CloudKit
import SettledCore

/// One group: its ledger of expenses and payments, balances with settle-up,
/// the activity trail, and members. Every edit goes through
/// `ExpenseGroup.apply` on a local copy and is persisted back to the
/// `SavedTrip` on change.
struct GroupDetailView: View {
    let saved: SavedTrip
    @State private var group: ExpenseGroup
    @State private var mode: Mode = .expenses
    @State private var showingAddExpense = false
    @State private var editingExpense: Expense?
    @State private var receiptFlow: BillFlowModel?
    @State private var exportFile: ExportFile?
    @State private var pendingShare: PendingShare?
    @State private var shareError: String?
    @Environment(CloudSyncEngine.self) private var cloud
    @State private var paymentDraft: PaymentDraft?
    @State private var showingMemberPicker = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var undoEntryID: UUID?
    @State private var undoTitle = ""
    @State private var undoTask: Task<Void, Never>?
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @Environment(\.modelContext) private var context

    enum Mode: String, CaseIterable {
        case expenses = "Expenses"
        case balances = "Balances"
        case activity = "Activity"
        case people = "People"
    }

    init(saved: SavedTrip) {
        self.saved = saved
        _group = State(initialValue: saved.group)
    }

    private var meID: Person.ID? { Me.parse(meIDString) }
    private var namer: Namer { Namer(group: group, meID: meID) }

    var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal)
                .padding(.top, 8)
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .expenses: expensesList
            case .balances: balancesList
            case .activity: activityList
            case .people: peopleList
            }
        }
        .background(Theme.groupedBackground)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAddExpense) {
            ExpenseEditorView(group: group, existing: nil, meID: meID) { expense in
                group.apply(.addEntry(.expense(expense)), by: meID)
            }
        }
        .sheet(item: $editingExpense) { expense in
            ExpenseEditorView(group: group, existing: expense, meID: meID) { updated in
                group.apply(.updateEntry(.expense(updated)), by: meID)
            }
        }
        .sheet(item: $paymentDraft) { draft in
            RecordPaymentView(group: group, draft: draft, meID: meID) { payment in
                if draft.existing == nil {
                    group.apply(.addEntry(.payment(payment)), by: meID)
                } else {
                    group.apply(.updateEntry(.payment(payment)), by: meID)
                }
            }
        }
        .fullScreenCover(item: $receiptFlow) { model in
            ReceiptFlowSheet(model: model)
        }
        .sheet(item: $exportFile) { file in
            ActivitySheet(items: [file.url])
        }
        .sheet(item: $pendingShare) { pending in
            ShareGroupSheet(share: pending.share, container: pending.container, title: pending.title) {
                saved.cloudZone = nil
            }
            .ignoresSafeArea()
        }
        .alert("Couldn't share this group", isPresented: Binding(get: { shareError != nil },
                                                                set: { if !$0 { shareError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .sheet(isPresented: $showingMemberPicker) {
            MemberPickerView(existingIDs: Set(group.people.map(\.id))) { people in
                for person in people {
                    group.apply(.addMember(person.withColorIndex(group.people.count)), by: meID)
                }
            }
        }
        .alert("Rename group", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Save") { group.apply(.rename(renameText), by: meID) }
            Button("Cancel", role: .cancel) {}
        }
        // Any mutation of `group` is written straight back to storage, and
        // a change made elsewhere (restore from the Activity tab) is picked up.
        .onChange(of: group) {
            saved.update(from: group)
            if saved.isShared {
                Task { await GroupSyncCoordinator.push(saved, engine: cloud) }
            }
        }
        .onChange(of: saved.updatedAt) {
            let latest = saved.group
            if latest != group { group = latest }
        }
        .safeAreaInset(edge: .bottom) {
            if let id = undoEntryID {
                undoBanner(id)
            }
        }
    }

    /// Members, total spent, and where I stand — always visible.
    private var headerCard: some View {
        let myBalance = meID.flatMap { id in
            SettlementEngine.balances(for: group).first(where: { $0.personID == id })
        }
        return HStack(spacing: 14) {
            if group.people.isEmpty {
                KindBadge(kind: group.kind, size: 44)
            } else {
                AvatarStack(people: group.people, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Total spent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Money.format(group.totalCents, currencyCode: group.currencyCode))
                    .font(.bigAmount)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if saved.isShared {
                Image(systemName: "icloud.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Shared through iCloud")
            }
            if let myBalance {
                StatusPill(text: namer.balanceLabel(myBalance), color: Theme.balanceColor(myBalance.cents))
            } else {
                Label(group.kind.title, systemImage: group.kind.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if mode == .expenses {
                Menu {
                    Button { showingAddExpense = true } label: { Label("Add expense", systemImage: "square.and.pencil") }
                    Button { startReceiptFlow() } label: { Label("Scan a receipt", systemImage: "doc.viewfinder") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(group.people.isEmpty)
            }
            if mode == .balances {
                ShareLink(item: settlementText) { Label("Share", systemImage: "square.and.arrow.up") }
                    .disabled(group.liveEntries.isEmpty)
            }
            if mode == .people {
                Button { showingMemberPicker = true } label: { Label("Add people", systemImage: "person.badge.plus") }
            }
            Menu {
                Button {
                    paymentDraft = PaymentDraft()
                } label: {
                    Label("Record a payment", systemImage: "arrow.right.circle")
                }
                .disabled(group.people.count < 2)
                Button {
                    renameText = group.name
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Picker("Group type", selection: kindBinding) {
                    ForEach(GroupKind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(kind)
                    }
                }
                Picker("Currency", selection: currencyBinding) {
                    ForEach(Currencies.options(including: group.currencyCode), id: \.self) { code in
                        Text("\(code) · \(Currencies.name(code))").tag(code)
                    }
                }
                Toggle("Simplify debts", isOn: simplifyBinding)
                Divider()
                Button {
                    shareViaCloud()
                } label: {
                    Label(saved.isShared ? "Manage iCloud sharing" : "Share live with iCloud",
                          systemImage: "person.crop.circle.badge.plus")
                }
                Button {
                    shareGroupFile()
                } label: {
                    Label("Share a copy of this group", systemImage: "square.and.arrow.up.on.square")
                }
                Button {
                    exportCSV()
                } label: {
                    Label("Export spreadsheet (CSV)", systemImage: "tablecells")
                }
                .disabled(group.liveEntries.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// Puts the group in iCloud and opens Apple's sharing screen. Everyone
    /// invited edits the same ledger; edits merge exactly as a shared file
    /// does, so the two ways of sharing agree.
    private func shareViaCloud() {
        Task {
            do {
                let (share, zone) = try await cloud.share(group, zone: saved.cloudZone)
                saved.cloudZone = zone
                saved.lastSyncedAt = .now
                pendingShare = PendingShare(share: share, container: cloud.sharingContainer, title: group.name)
            } catch {
                shareError = error.localizedDescription
            }
        }
    }

    /// Writes the whole group to a `.settled` file for AirDrop or
    /// Messages. Whoever opens it merges it into their own copy.
    private func shareGroupFile() {
        let myName = meID.flatMap { group.person(withID: $0)?.name }
        if let url = GroupSharing.export(group, exportedBy: myName) {
            exportFile = ExportFile(url: url)
        }
    }

    private func exportCSV() {
        if let url = Exports.write(GroupCSV.render(group), named: "\(group.name).csv") {
            exportFile = ExportFile(url: url)
        }
    }

    private func exportStatement(for person: Person) {
        let statement = Statement.make(for: person.id, in: group)
        Task { @MainActor in
            if let url = StatementPDF.render(statement) {
                exportFile = ExportFile(url: url)
            }
        }
    }

    /// Scan a receipt for this group: the flow starts with the members as
    /// the diners and ends by adding an itemized expense here.
    private func startReceiptFlow() {
        let model = BillFlowModel()
        model.people = group.people
        model.target = BillFlowModel.GroupTarget(groupID: group.id, groupName: group.name,
                                                 currencyCode: group.currencyCode, existingExpense: nil)
        model.onItemized = { expense in
            for person in expense.itemizedBill?.people ?? [] where group.person(withID: person.id) == nil {
                group.apply(.addMember(person.withColorIndex(group.people.count)), by: meID)
            }
            group.apply(.addEntry(.expense(expense)), by: meID)
            receiptFlow = nil
        }
        receiptFlow = model
    }

    private var kindBinding: Binding<GroupKind> {
        Binding(get: { group.kind }, set: { group.apply(.setKind($0), by: meID) })
    }

    private var currencyBinding: Binding<String> {
        Binding(get: { group.currencyCode }, set: { group.apply(.setCurrency($0), by: meID) })
    }

    private var simplifyBinding: Binding<Bool> {
        Binding(get: { group.simplifyDebts }, set: { group.apply(.setSimplifyDebts($0), by: meID) })
    }

    // MARK: - Expenses

    private var sortedEntries: [LedgerEntry] {
        group.liveEntries.sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
    }

    @ViewBuilder
    private var expensesList: some View {
        if group.people.isEmpty {
            ContentUnavailableView {
                Label("Add people first", systemImage: "person.2")
            } description: {
                Text("Add who's in this group, then record expenses.")
            } actions: {
                Button("Add people") { showingMemberPicker = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if sortedEntries.isEmpty {
            ContentUnavailableView {
                Label("No expenses yet", systemImage: "creditcard")
            } description: {
                Text("Tap + to add what someone paid for.")
            }
        } else {
            List {
                ForEach(sortedEntries) { entry in
                    entryRow(entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LedgerEntry) -> some View {
        switch entry {
        case .expense(let expense):
            NavigationLink {
                ExpenseDetailView(group: $group, expenseID: expense.id, meID: meID)
            } label: {
                expenseRow(expense)
            }
        case .payment(let payment):
            Button {
                paymentDraft = PaymentDraft(existing: payment)
            } label: {
                paymentRow(payment)
            }
            .foregroundStyle(.primary)
        }
    }

    private func expenseRow(_ expense: Expense) -> some View {
        HStack(spacing: 12) {
            DateBadge(date: expense.date)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: expense.category.systemImage)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text(expense.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                Text("\(namer.payersLine(expense)) \(Money.format(expense.amountCents, currencyCode: expense.currencyCode))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let line = myLine(for: expense) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(line.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(line.amount)
                        .font(.amount)
                        .monospacedDigit()
                        .foregroundStyle(line.color)
                }
            } else {
                Text(Money.format(expense.amountCents, currencyCode: expense.currencyCode))
                    .font(.amount)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private func paymentRow(_ payment: Payment) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: "arrow.right", color: Theme.positive, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(namer.paymentLine(payment))
                    .font(.body.weight(.medium))
                Text("\(payment.method.title) · \(payment.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Money.format(payment.cents, currencyCode: payment.currencyCode))
                .font(.amount)
                .monospacedDigit()
                .foregroundStyle(Theme.positive)
        }
        .padding(.vertical, 2)
    }

    /// "you lent" / "you borrowed" with the amount, for an expense I'm part of.
    private func myLine(for expense: Expense) -> (label: String, amount: String, color: Color)? {
        guard let meID else { return nil }
        let contribution = SettlementEngine.contribution(for: expense, knownPeople: Set(group.people.map(\.id)))
        let net = contribution.net[meID] ?? 0
        let code = contribution.currencyCode
        if net > 0 { return ("you lent", Money.format(net, currencyCode: code), Theme.positive) }
        if net < 0 { return ("you borrowed", Money.format(-net, currencyCode: code), Theme.negative) }
        let owed = contribution.owed[meID] ?? 0
        if owed > 0 { return ("your share", Money.format(owed, currencyCode: code), .secondary) }
        return nil
    }

    private func delete(_ entry: LedgerEntry) {
        guard group.apply(.deleteEntry(entry.id), by: meID) else { return }
        undoTitle = group.title(of: entry)
        undoEntryID = entry.id
        undoTask?.cancel()
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { undoEntryID = nil }
        }
    }

    private func undoBanner(_ id: UUID) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("Deleted \(undoTitle)")
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button("Undo") {
                group.apply(.restoreEntry(id), by: meID)
                undoTask?.cancel()
                undoEntryID = nil
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Balances & settle up

    private var balancesList: some View {
        let settlements = SettlementEngine.settlements(for: group)
        let multi = settlements.count > 1
        return List {
            ForEach(settlements, id: \.currencyCode) { settlement in
                let maxCents = settlement.balances.map { abs($0.cents) }.max() ?? 0
                Section(multi ? "Balances · \(settlement.currencyCode)" : "Balances") {
                    if group.liveEntries.isEmpty {
                        Text("No expenses yet.").foregroundStyle(Color.secondary)
                    }
                    ForEach(settlement.balances) { balance in
                        balanceRow(balance, maxCents: maxCents, currencyCode: settlement.currencyCode)
                    }
                }

                Section {
                    if settlement.transfers.isEmpty {
                        settledUpLabel
                    } else {
                        ForEach(settlement.transfers, id: \.self) { transfer in
                            transferRow(transfer, currencyCode: settlement.currencyCode)
                        }
                    }
                } header: {
                    Text(multi ? "Settle up · \(settlement.currencyCode)" : "Settle up")
                }
            }

            Section {
                Toggle("Simplify debts", isOn: simplifyBinding)
            } footer: {
                Text(group.simplifyDebts
                     ? "The fewest payments that clear every balance."
                     : "Debts as they happened, netted per pair. Turn on simplify for the fewest payments.")
            }
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
    }

    private func balanceRow(_ balance: Balance, maxCents: Int, currencyCode: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let person = group.person(withID: balance.personID) {
                    Avatar(person: person, size: 36)
                }
                Text(namer.name(balance.personID))
                    .font(.body.weight(.medium))
                Spacer()
                Text(namer.balanceVerbLabel(balance, currencyCode: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.balanceColor(balance.cents))
            }
            BalanceBar(cents: balance.cents, maxCents: maxCents)
        }
        .padding(.vertical, 4)
    }

    private func transferRow(_ transfer: Transfer, currencyCode: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                avatar(for: transfer.fromID)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                avatar(for: transfer.toID)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(namer.name(transfer.fromID)) → \(namer.name(transfer.toID))")
                    .font(.subheadline.weight(.medium))
                Text(Money.format(transfer.cents, currencyCode: currencyCode))
                    .font(.amount)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button {
                paymentDraft = PaymentDraft(fromID: transfer.fromID, toID: transfer.toID, cents: transfer.cents,
                                            currencyCode: currencyCode)
            } label: {
                Label("Record", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func avatar(for id: Person.ID) -> some View {
        Avatar(person: group.person(withID: id) ?? Person(name: "?"), size: 28)
    }

    private var settledUpLabel: some View {
        let empty = group.liveEntries.isEmpty
        return Label(empty ? "Nothing to settle yet" : "All settled up 🎉",
                     systemImage: empty ? "tray" : "checkmark.seal.fill")
            .foregroundStyle(empty ? Color.secondary : Theme.positive)
    }

    // MARK: - Activity

    @ViewBuilder
    private var activityList: some View {
        if group.activity.isEmpty {
            ContentUnavailableView {
                Label("Nothing yet", systemImage: "clock")
            } description: {
                Text("Expenses, payments, and edits show up here.")
            }
        } else {
            List {
                ForEach(Array(group.activity.reversed())) { event in
                    ActivityEventRow(
                        event: event,
                        groupName: nil,
                        actorName: event.actorID.map { namer.name($0) },
                        restorable: isRestorable(event)
                    ) {
                        if let id = event.subjectID { group.apply(.restoreEntry(id), by: meID) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        }
    }

    private func isRestorable(_ event: ActivityEvent) -> Bool {
        guard event.kind == .entryDeleted, let id = event.subjectID else { return false }
        return group.entry(withID: id)?.isDeleted == true
    }

    // MARK: - People

    private var peopleList: some View {
        List {
            Section {
                ForEach(group.people) { person in
                    HStack(spacing: 12) {
                        Avatar(person: person, size: 36)
                        Text(person.name).font(.body.weight(.medium))
                        if namer.isMe(person.id) {
                            Text("you").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if group.isReferenced(person.id) {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button {
                            exportStatement(for: person)
                        } label: {
                            Label("Reimbursement statement (PDF)", systemImage: "doc.text")
                        }
                    }
                }
                .onDelete { offsets in
                    // `apply` refuses to remove anyone tied to an entry, so
                    // balances stay consistent.
                    for person in offsets.map({ group.people[$0] }) {
                        group.apply(.removeMember(person.id), by: meID)
                    }
                }
            } footer: {
                Text("People in an expense or payment can't be removed. A lock marks them. Touch and hold a person for their reimbursement statement.")
            }

            Section {
                Button {
                    showingMemberPicker = true
                } label: {
                    Label("Add people", systemImage: "person.badge.plus")
                }
                if let meID, group.person(withID: meID) == nil,
                   let me = PeopleDirectory.find(id: meID, in: context) {
                    Button {
                        group.apply(.addMember(me.person(colorIndex: group.people.count)), by: meID)
                    } label: {
                        Label("Add yourself (\(me.name))", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
    }

    // MARK: - Helpers

    private func splitSummary(_ expense: Expense) -> String {
        switch expense.split {
        case .equally(let ids): return "split \(ids.count) ways"
        case .shares: return "by shares"
        case .percentages: return "by percent"
        case .exactCents: return "exact amounts"
        case .adjustment: return "with adjustments"
        }
    }

    /// Neutral names (no "You") since this goes to the group chat.
    private var settlementText: String {
        var lines = ["\(group.name) — settle up"]
        let settlements = SettlementEngine.settlements(for: group)
        if settlements.allSatisfy(\.isSettled) {
            lines.append("All settled up.")
        } else {
            for settlement in settlements {
                for transfer in settlement.transfers {
                    lines.append("\(group.name(of: transfer.fromID)) → \(group.name(of: transfer.toID)): \(Money.format(transfer.cents, currencyCode: settlement.currencyCode))")
                }
            }
        }
        lines.append("")
        lines.append("Total spent \(Money.format(group.totalCents, currencyCode: group.currencyCode))")
        return lines.joined(separator: "\n")
    }
}

/// What the payment sheet opens with: a suggested transfer, an existing
/// payment to edit, or nothing.
struct PaymentDraft: Identifiable {
    let id = UUID()
    var fromID: Person.ID?
    var toID: Person.ID?
    var cents: Int
    /// nil means the group's currency.
    var currencyCode: String?
    var existing: Payment?

    init(fromID: Person.ID? = nil, toID: Person.ID? = nil, cents: Int = 0, currencyCode: String? = nil, existing: Payment? = nil) {
        self.fromID = existing?.fromID ?? fromID
        self.toID = existing?.toID ?? toID
        self.cents = existing?.cents ?? cents
        self.currencyCode = existing?.currencyCode ?? currencyCode
        self.existing = existing
    }
}
