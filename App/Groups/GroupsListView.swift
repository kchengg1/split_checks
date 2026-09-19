import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import SettledCore

/// The Groups tab home: a hero card with your overall position when the
/// app knows who you are, then every group by last activity.
struct GroupsListView: View {
    @Query(sort: \SavedTrip.updatedAt, order: .reverse) private var groups: [SavedTrip]
    @Environment(\.modelContext) private var context
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var showingNew = false
    @State private var showingImporter = false
    @State private var incoming: GroupDocument?
    @State private var importFailed = false

    private var meID: Person.ID? { Me.parse(meIDString) }

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No groups yet", systemImage: "person.3.fill")
                } description: {
                    Text("Create a group for a trip, a home, or any shared tab to track who owes whom.")
                } actions: {
                    Button("New group") { showingNew = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                List {
                    if let overall = overallBalance {
                        overallHero(overall)
                            .cardRow()
                    }
                    Section {
                        ForEach(groups) { saved in
                            NavigationLink(value: saved.id) {
                                row(saved)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(groups[index]) }
                        }
                    } header: {
                        Text("Your groups")
                    }
                }
            }
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingNew = true } label: { Label("New group", systemImage: "plus") }
                    Button { showingImporter = true } label: { Label("Import a shared group", systemImage: "square.and.arrow.down") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.settledGroup, .json]) { result in
            guard case .success(let url) = result, let document = GroupSharing.read(from: url) else {
                importFailed = true
                return
            }
            incoming = document
        }
        .sheet(item: $incoming) { document in
            ImportGroupSheet(document: document)
        }
        .alert("Couldn't read that file", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It isn't a Settled group file, or it's from a newer version of the app.")
        }
        .navigationDestination(for: UUID.self) { id in
            if let saved = groups.first(where: { $0.id == id }) {
                GroupDetailView(saved: saved)
            }
        }
        .sheet(isPresented: $showingNew) {
            NewGroupSheet { group in
                context.insert(SavedTrip(group: group))
            }
        }
    }

    // MARK: - Rows

    private func row(_ saved: SavedTrip) -> some View {
        let group = saved.group
        let myBalance = meID.flatMap { id in
            SettlementEngine.balances(for: group).first(where: { $0.personID == id })
        }
        return HStack(spacing: 12) {
            KindBadge(kind: saved.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(saved.name)
                    .font(.cardTitle)
                Text("\(saved.peopleCount) people · \(Money.format(saved.totalCents, currencyCode: group.currencyCode))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            if let myBalance {
                StatusPill(text: Namer(group: group, meID: meID).balanceLabel(myBalance),
                           color: Theme.balanceColor(myBalance.cents))
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Overall balance

    /// My net position summed across groups, per currency.
    private struct Overall {
        var owe: [String: Int] = [:]
        var owed: [String: Int] = [:]
        var isEmpty: Bool { owe.isEmpty && owed.isEmpty }
    }

    private var overallBalance: Overall? {
        guard let meID else { return nil }
        var overall = Overall()
        var involved = false
        for saved in groups {
            let group = saved.group
            guard let balance = SettlementEngine.balances(for: group).first(where: { $0.personID == meID }) else { continue }
            involved = true
            if balance.cents < 0 { overall.owe[group.currencyCode, default: 0] += -balance.cents }
            if balance.cents > 0 { overall.owed[group.currencyCode, default: 0] += balance.cents }
        }
        return involved ? overall : nil
    }

    private func overallHero(_ overall: Overall) -> some View {
        HeroCard {
            Text("Overall")
                .font(.subheadline.weight(.medium))
                .opacity(0.85)
            if overall.isEmpty {
                Text("All settled up ✨")
                    .font(.heroAmount)
                Text("Nobody owes anybody. Enjoy it.")
                    .font(.subheadline)
                    .opacity(0.85)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    if !overall.owe.isEmpty {
                        heroStat("You owe", overall.owe)
                    }
                    if !overall.owed.isEmpty {
                        heroStat("You are owed", overall.owed)
                    }
                }
            }
        }
    }

    private func heroStat(_ title: String, _ amounts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .opacity(0.85)
            ForEach(amounts.keys.sorted(), id: \.self) { code in
                Text(Money.format(amounts[code] ?? 0, currencyCode: code))
                    .font(.heroAmount)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

/// Name and type for a new group. You're added as the first member when
/// the app knows who you are.
struct NewGroupSheet: View {
    let onCreate: (ExpenseGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var name = ""
    @State private var kind: GroupKind = .trip
    @State private var currencyCode = Locale.current.currency?.identifier ?? "USD"
    @State private var includeMe = true
    @FocusState private var nameFocused: Bool

    private var me: SavedPerson? {
        Me.parse(meIDString).flatMap { PeopleDirectory.find(id: $0, in: context) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        KindBadge(kind: kind, size: 48)
                        TextField("Group name", text: $name)
                            .font(.cardTitle)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(create)
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(GroupKind.allCases, id: \.self) { kind in
                            Label(kind.title, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(Currencies.options(including: currencyCode), id: \.self) { code in
                            Text("\(code) · \(Currencies.name(code))").tag(code)
                        }
                    }
                } footer: {
                    Text("The type only changes the icon. Expenses can be in any currency; this is the default.")
                }
                if let me {
                    Section {
                        Toggle(isOn: $includeMe) {
                            HStack {
                                Text("Add yourself")
                                Spacer()
                                PersonChip(person: me.person)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var group = ExpenseGroup(name: trimmed, kind: kind, currencyCode: currencyCode)
        if includeMe, let me {
            group.apply(.addMember(me.person(colorIndex: 0)), by: me.id)
            me.lastUsedAt = .now
        }
        onCreate(group)
        dismiss()
    }
}
