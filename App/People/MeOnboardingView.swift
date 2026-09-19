import SwiftUI
import SwiftData
import SettledCore

/// First-launch (and Settings) sheet: "What's your name?" Creates or picks
/// the directory person that is *me*, so balances can say "you owe".
/// Skipping is fine — everything works with neutral wording.
struct MeOnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPerson.lastUsedAt, order: .reverse) private var people: [SavedPerson]
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @AppStorage(Me.onboardedKey) private var onboarded = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        IconBadge(systemImage: "person.fill", color: Theme.accent, size: 64)
                        Text("Who's holding the phone?")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("Tell the app who you are so balances read \"you owe Sam\" — and you're added to new groups automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("Your name")
                } footer: {
                    Text("This stays on your phone.")
                }

                if !people.isEmpty {
                    Section("Or pick yourself") {
                        ForEach(people) { saved in
                            Button {
                                choose(saved)
                            } label: {
                                HStack {
                                    PersonChip(person: saved.person)
                                    Spacer()
                                    if saved.id.uuidString == meIDString {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("This is you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        choose(PeopleDirectory.findOrCreate(named: trimmed, in: context))
    }

    private func choose(_ saved: SavedPerson) {
        meIDString = saved.id.uuidString
        finish()
    }

    private func finish() {
        onboarded = true
        dismiss()
    }
}
