import SwiftUI
import SplitChecksCore

/// Step 2: who's at the table.
struct PeopleView: View {
    @Environment(BillFlowModel.self) private var model
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

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
