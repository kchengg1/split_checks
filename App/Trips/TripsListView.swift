import SwiftUI
import SwiftData
import SplitChecksCore

/// The Trips tab home: every trip, newest activity first.
struct TripsListView: View {
    @Query(sort: \SavedTrip.updatedAt, order: .reverse) private var trips: [SavedTrip]
    @Environment(\.modelContext) private var context
    @State private var showingNew = false
    @State private var newName = ""

    var body: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView {
                    Label("No trips yet", systemImage: "airplane")
                } description: {
                    Text("Create a trip to track shared expenses and see who owes whom.")
                } actions: {
                    Button("New trip") { showingNew = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(trips) { saved in
                        NavigationLink(value: saved.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.name).font(.headline)
                                Text("\(saved.peopleCount) people · \(Money.format(saved.totalCents))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(trips[index]) }
                    }
                }
            }
        }
        .navigationTitle("Trips")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNew = true } label: { Label("New trip", systemImage: "plus") }
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let saved = trips.first(where: { $0.id == id }) {
                TripDetailView(saved: saved)
            }
        }
        .alert("New trip", isPresented: $showingNew) {
            TextField("Trip name", text: $newName)
            Button("Create") { createTrip() }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Name your trip — a getaway, a dinner, a shared house.")
        }
    }

    private func createTrip() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        let trip = Trip(name: trimmed.isEmpty ? "Trip" : trimmed)
        context.insert(SavedTrip(trip: trip))
        newName = ""
    }
}
