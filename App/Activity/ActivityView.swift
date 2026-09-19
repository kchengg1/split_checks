import SwiftUI
import SwiftData
import SettledCore

/// The Activity tab: every group's trail, newest first, grouped by day.
/// Deleted entries can be restored from here.
struct ActivityView: View {
    @Query(sort: \SavedTrip.updatedAt, order: .reverse) private var groups: [SavedTrip]
    @AppStorage(Me.defaultsKey) private var meIDString = ""

    private var meID: Person.ID? { Me.parse(meIDString) }

    private struct Item: Identifiable {
        let event: ActivityEvent
        let saved: SavedTrip
        let group: ExpenseGroup
        var id: UUID { event.id }
    }

    private var items: [Item] {
        var all: [Item] = []
        for saved in groups {
            let group = saved.group
            for event in group.activity {
                all.append(Item(event: event, saved: saved, group: group))
            }
        }
        all.sort { $0.event.at > $1.event.at }
        return Array(all.prefix(300))
    }

    private var days: [(day: Date, items: [Item])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.event.at) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No activity yet", systemImage: "clock")
                } description: {
                    Text("Expenses, payments, and edits across your groups show up here.")
                }
            } else {
                List {
                    ForEach(days, id: \.day) { section in
                        Section(section.day.formatted(date: .abbreviated, time: .omitted)) {
                            ForEach(section.items) { item in
                                NavigationLink(value: item.saved.id) {
                                    ActivityEventRow(
                                        event: item.event,
                                        groupName: item.group.name,
                                        actorName: item.event.actorID.map { Namer(group: item.group, meID: meID).name($0) },
                                        restorable: isRestorable(item)
                                    ) {
                                        restore(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .navigationDestination(for: UUID.self) { id in
            if let saved = groups.first(where: { $0.id == id }) {
                GroupDetailView(saved: saved)
            }
        }
    }

    private func isRestorable(_ item: Item) -> Bool {
        guard item.event.kind == .entryDeleted, let id = item.event.subjectID else { return false }
        return item.group.entry(withID: id)?.isDeleted == true
    }

    private func restore(_ item: Item) {
        guard let id = item.event.subjectID else { return }
        var group = item.saved.group
        if group.apply(.restoreEntry(id), by: meID) {
            item.saved.update(from: group)
        }
    }
}

/// One line of the trail. Shared by the Activity tab and a group's own
/// activity view.
struct ActivityEventRow: View {
    let event: ActivityEvent
    let groupName: String?
    let actorName: String?
    let restorable: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: symbol, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if restorable {
                Button("Restore", action: onRestore)
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let groupName { parts.append(groupName) }
        if let actorName { parts.append("by \(actorName)") }
        parts.append(event.at.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch event.kind {
        case .entryAdded: return "plus"
        case .entryEdited: return "pencil"
        case .entryDeleted: return "trash"
        case .entryRestored: return "arrow.uturn.backward"
        case .memberAdded: return "person.badge.plus"
        case .memberRemoved: return "person.badge.minus"
        case .groupRenamed: return "textformat"
        case .settingsChanged: return "gearshape"
        }
    }

    private var color: Color {
        switch event.kind {
        case .entryAdded: return Theme.positive
        case .entryEdited: return .blue
        case .entryDeleted: return Theme.negative
        case .entryRestored: return .orange
        default: return .secondary
        }
    }
}
