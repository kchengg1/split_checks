import SwiftUI
import SwiftData
import SplitChecksCore

/// Step 2: who's at the table. Names from recent bills show up as
/// one-tap suggestions.
struct PeopleView: View {
    @Environment(BillFlowModel.self) private var model
    @Query(sort: \SavedBill.date, order: .reverse) private var recentBills: [SavedBill]
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    /// Frequent-diner suggestions: names from the last few bills that
    /// aren't already on this one, most recent first.
    private var suggestions: [String] {
        let current = Set(model.people.map { $0.name.lowercased() })
        var seen: Set<String> = []
        var result: [String] = []
        for bill in recentBills.prefix(10) {
            for name in bill.peopleNames {
                let key = name.lowercased()
                if !current.contains(key), !seen.contains(key) {
                    seen.insert(key)
                    result.append(name)
                }
            }
        }
        return Array(result.prefix(6))
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
                            ForEach(suggestions, id: \.self) { name in
                                Button {
                                    model.addPerson(name: name)
                                } label: {
                                    Label(name, systemImage: "plus")
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
        model.addPerson(name: newName)
        newName = ""
        nameFocused = true
    }
}
