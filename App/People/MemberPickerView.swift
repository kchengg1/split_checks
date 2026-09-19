import SwiftUI
import SwiftData
import SettledCore

/// Add people to a group from the directory, or type a new name. Returns
/// `Person` values whose IDs are the directory's, so the same friend is
/// one person across every group.
struct MemberPickerView: View {
    let existingIDs: Set<Person.ID>
    let onDone: ([Person]) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPerson.lastUsedAt, order: .reverse) private var people: [SavedPerson]
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var selected: Set<Person.ID> = []
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private var candidates: [SavedPerson] {
        people.filter { !existingIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New person", text: $newName)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(addNew)
                        Button(action: addNew) {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Add person")
                    }
                } footer: {
                    if candidates.isEmpty {
                        Text("People you add here are remembered for next time.")
                    }
                }

                if !candidates.isEmpty {
                    Section("People") {
                        ForEach(candidates) { saved in
                            Button {
                                toggle(saved.id)
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(saved.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(saved.id) ? Color.accentColor : Color.secondary)
                                    PersonChip(person: saved.person)
                                    if saved.id.uuidString == meIDString {
                                        Text("you").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { done() }
                        .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func toggle(_ id: Person.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func addNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let saved = PeopleDirectory.findOrCreate(named: trimmed, in: context)
        if !existingIDs.contains(saved.id) {
            selected.insert(saved.id)
        }
        newName = ""
        nameFocused = true
    }

    private func done() {
        // Directory order, so colors and list order are stable.
        let chosen = people.filter { selected.contains($0.id) }
        PeopleDirectory.touch(chosen.map(\.id), in: context)
        onDone(chosen.map(\.person))
        dismiss()
    }
}
