import SwiftUI
import SwiftData
import SettledCore

/// Who you are, the people directory, and the boring-but-important links.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPerson.name) private var people: [SavedPerson]
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @Environment(CloudSyncEngine.self) private var cloud
    @State private var showingMe = false

    private var cloudStatus: String {
        switch cloud.status {
        case .unknown: return "Checking…"
        case .unavailable(let why): return why
        case .idle: return "Ready"
        case .syncing: return "Syncing…"
        case .failed(let why): return why
        }
    }

    private var me: SavedPerson? {
        people.first { $0.id.uuidString == meIDString }
    }

    var body: some View {
        List {
            Section {
                if let me {
                    HStack(spacing: 14) {
                        Avatar(person: me.person, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.name).font(.cardTitle)
                            Text("That's you").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change") { showingMe = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        showingMe = true
                    } label: {
                        Label("Set up who you are", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } header: {
                Text("You")
            } footer: {
                Text("Lets balances say \"you owe Sam\" and puts you in new groups automatically.")
            }

            Section {
                if people.isEmpty {
                    Text("People you add to bills and groups are remembered here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(people) { saved in
                    NavigationLink {
                        PersonEditView(saved: saved)
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(person: saved.person, size: 32)
                            Text(saved.name)
                            if saved.id.uuidString == meIDString {
                                Text("you").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let saved = people[index]
                        if saved.id.uuidString == meIDString { meIDString = "" }
                        context.delete(saved)
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Text("Removing someone here doesn't change the groups they're already in.")
            }

            Section {
                LabeledContent("iCloud") {
                    Text(cloudStatus)
                        .foregroundStyle(cloud.status.isAvailable ? Theme.positive : .secondary)
                }
            } header: {
                Text("Sharing")
            } footer: {
                Text("Groups stay on this phone until you share one. Sharing a group live stores it in your own iCloud so the people you invite see the same ledger.")
            }

            Section("About") {
                Link("Privacy policy", destination: URL(string: "https://kchengg1.github.io/settled/privacy.html")!)
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                Text("No account, no server. Everything stays on this phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await cloud.refreshAvailability() }
        .sheet(isPresented: $showingMe) {
            MeOnboardingView()
        }
    }
}

/// Rename a person or add the handles used for settle-up hand-offs. Saved
/// changes are written into every group that embeds this person.
struct PersonEditView: View {
    let saved: SavedPerson
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var handles: PaymentHandles

    init(saved: SavedPerson) {
        self.saved = saved
        _name = State(initialValue: saved.name)
        _handles = State(initialValue: saved.handles)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
            }
            Section {
                handleField("Venmo", text: $handles.venmo)
                handleField("PayPal", text: $handles.paypal)
                handleField("Cash App", text: $handles.cashApp)
                handleField("Zelle", text: $handles.zelle)
                handleField("Phone", text: $handles.phone)
            } header: {
                Text("Pay them back with")
            } footer: {
                Text("Optional. Used to hand off to a payment app when you settle up — never shared anywhere else.")
            }
        }
        .navigationTitle(saved.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func handleField(_ title: String, text: Binding<String?>) -> some View {
        TextField(title, text: Binding(
            get: { text.wrappedValue ?? "" },
            set: { text.wrappedValue = $0.isEmpty ? nil : $0 }
        ))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func save() {
        saved.name = name.trimmingCharacters(in: .whitespaces)
        saved.handles = handles
        PeopleDirectory.propagate(saved, in: context)
        dismiss()
    }
}
