import SwiftUI
import SwiftData
import SettledCore

/// Everyone you share a group with, and where you stand with each of them
/// across all groups.
struct FriendsView: View {
    @Query(sort: \SavedTrip.updatedAt, order: .reverse) private var savedGroups: [SavedTrip]
    @Query(sort: \SavedPerson.name) private var people: [SavedPerson]
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var showingMe = false

    private var meID: Person.ID? { Me.parse(meIDString) }

    private var friends: [FriendBalance] {
        guard let meID else { return [] }
        return FriendLedger.balances(groups: savedGroups.map(\.group), meID: meID)
    }

    var body: some View {
        Group {
            if meID == nil {
                ContentUnavailableView {
                    Label("Who are you?", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Tell the app which person is you to see what friends owe you across every group.")
                } actions: {
                    Button("Set up") { showingMe = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if friends.isEmpty {
                ContentUnavailableView {
                    Label("No friends yet", systemImage: "person.2")
                } description: {
                    Text("People you share a group with show up here.")
                }
            } else {
                List {
                    ForEach(friends) { friend in
                        NavigationLink(value: FriendRoute(id: friend.personID)) {
                            row(friend)
                        }
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .navigationDestination(for: FriendRoute.self) { route in
            FriendDetailView(friendID: route.id)
        }
        .navigationDestination(for: GroupRoute.self) { route in
            if let saved = savedGroups.first(where: { $0.id == route.id }) {
                GroupDetailView(saved: saved)
            }
        }
        .sheet(isPresented: $showingMe) {
            MeOnboardingView()
        }
    }

    private func row(_ friend: FriendBalance) -> some View {
        HStack(spacing: 12) {
            Avatar(person: person(for: friend), size: 40)
            Text(friend.name)
                .font(.cardTitle)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if friend.isSettled {
                    StatusPill(text: "settled up", color: .secondary)
                } else {
                    ForEach(friend.byCurrency.keys.sorted(), id: \.self) { code in
                        let cents = friend.byCurrency[code] ?? 0
                        StatusPill(text: FriendWording.pill(cents: cents, currencyCode: code),
                                   color: Theme.balanceColor(cents))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func person(for friend: FriendBalance) -> Person {
        people.first { $0.id == friend.personID }?.person
            ?? Person(id: friend.personID, name: friend.name,
                      colorIndex: Int(friend.personID.uuid.0) % ChipPalette.colors.count)
    }
}

/// Navigation values for the Friends stack (kept distinct from the raw
/// UUIDs the Groups stack uses).
struct FriendRoute: Hashable { let id: Person.ID }
struct GroupRoute: Hashable { let id: UUID }

enum FriendWording {
    /// "owes you $12.00" / "you owe $12.00"; positive means they owe me.
    static func pill(cents: Int, currencyCode: String) -> String {
        let amount = Money.format(abs(cents), currencyCode: currencyCode)
        return cents > 0 ? "owes you \(amount)" : "you owe \(amount)"
    }
}
