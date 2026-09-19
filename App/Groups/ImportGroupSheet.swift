import SwiftUI
import SwiftData
import SettledCore

/// What arrives when someone sends you a group file: either a group you
/// already have (merge it) or a new one (add it). Shows what will change
/// before anything is written.
struct ImportGroupSheet: View {
    let document: GroupDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var savedGroups: [SavedTrip]
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var imported = false

    private var existing: SavedTrip? {
        savedGroups.first { $0.id == document.group.id }
    }

    private var preview: (group: ExpenseGroup, summary: MergeSummary)? {
        existing.map { $0.group.merging(document.group) }
    }

    var body: some View {
        NavigationStack {
            List {
                header
                    .cardRow()

                if let preview {
                    Section {
                        Text(preview.summary.sentence)
                            .font(.cardTitle)
                        if preview.summary.isEmpty {
                            Text("You already have everything in this file.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("What's new")
                    } footer: {
                        Text("Nothing is lost: edits from both phones are kept, the most recent one wins, and deletions stay deleted.")
                    }

                    Section("After merging") {
                        LabeledContent("Expenses", value: "\(preview.group.expenses.count)")
                        LabeledContent("Payments", value: "\(preview.group.payments.count)")
                        LabeledContent("People", value: "\(preview.group.people.count)")
                        LabeledContent("Total spent",
                                       value: Money.format(preview.group.totalCents, currencyCode: preview.group.currencyCode))
                    }
                } else {
                    Section {
                        LabeledContent("Expenses", value: "\(document.group.expenses.count)")
                        LabeledContent("Payments", value: "\(document.group.payments.count)")
                        LabeledContent("People", value: document.group.people.map(\.name).joined(separator: ", "))
                        LabeledContent("Total spent",
                                       value: Money.format(document.group.totalCents, currencyCode: document.group.currencyCode))
                    } header: {
                        Text("New group")
                    } footer: {
                        Text("This group isn't on this phone yet. Adding it keeps a full copy here.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.groupedBackground)
            .navigationTitle(existing == nil ? "Add group" : "Merge group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Merge") { apply() }
                }
            }
            .sensoryFeedback(.success, trigger: imported)
        }
    }

    private var header: some View {
        Card {
            HStack(spacing: 14) {
                KindBadge(kind: document.group.kind, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.group.name).font(.cardTitle)
                    Text(sentFrom)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var sentFrom: String {
        let when = document.exportedAt.formatted(date: .abbreviated, time: .shortened)
        if let by = document.exportedBy, !by.isEmpty { return "Shared by \(by) · \(when)" }
        return "Shared \(when)"
    }

    private func apply() {
        let meID = Me.parse(meIDString)
        if let existing {
            existing.update(from: existing.group.merged(with: document.group))
        } else {
            context.insert(SavedTrip(group: document.group))
        }
        // Everyone in the file joins the people directory, so they're one
        // person across groups here too.
        PeopleDirectory.register(document.group.people, in: context)
        if let meID, document.group.person(withID: meID) != nil {
            PeopleDirectory.touch([meID], in: context)
        }
        imported = true
        dismiss()
    }
}
