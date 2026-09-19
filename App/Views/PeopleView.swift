import SwiftUI
import SwiftData
import SettledCore

/// Step 2: who's at the table. People come from the directory, so a name
/// typed here is the same person as in any group; recent people show up
/// as one-tap suggestions.
struct PeopleView: View {
    @Environment(BillFlowModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPerson.lastUsedAt, order: .reverse) private var directory: [SavedPerson]
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    /// Suggestions: you first, then the most recently used people who
    /// aren't already on this bill.
    private var suggestions: [SavedPerson] {
        let current = Set(model.people.map(\.id))
        var result = directory.filter { !current.contains($0.id) }
        if let index = result.firstIndex(where: { $0.id.uuidString == meIDString }), index > 0 {
            result.insert(result.remove(at: index), at: 0)
        }
        return Array(result.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.people.isEmpty {
                    ContentUnavailableView(
                        "Nobody yet",
                        systemImage: "person.2",
                        description: Text("Add everyone who's splitting the bill.")
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(model.people) { person in
                            PersonChip(person: person)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        model.removePerson(person)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }

                HStack {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(addPerson)
                    Button(action: addPerson) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add person")
                }

                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(suggestions) { saved in
                                Button {
                                    add(saved)
                                } label: {
                                    Label(saved.id.uuidString == meIDString ? "\(saved.name) (you)" : saved.name,
                                          systemImage: "plus")
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Capsule().strokeBorder(.secondary))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Who's here?")
        .safeAreaInset(edge: .bottom) {
            NavigationLink(value: BillStep.assign) {
                Text("Next: Assign items")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.people.isEmpty)
            .padding()
            .background(.bar)
        }
    }

    private func addPerson() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        add(PeopleDirectory.findOrCreate(named: trimmed, in: context))
        newName = ""
        nameFocused = true
    }

    private func add(_ saved: SavedPerson) {
        saved.lastUsedAt = .now
        model.addPerson(saved.person(colorIndex: model.people.count))
    }
}
