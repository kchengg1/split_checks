import SwiftUI
import SplitChecksCore

/// Step 3: "paint" items with people. Select a person chip, then tap items
/// to toggle them for that person. Items tapped by several people are shared.
struct AssignView: View {
    @Environment(BillFlowModel.self) private var model
    @State private var selectedPersonID: Person.ID?

    private var selectedPerson: Person? {
        model.people.first { $0.id == selectedPersonID }
    }

    private var assignedCount: Int {
        model.items.count - model.result.unassignedItemIDs.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.people) { person in
                        Button {
                            selectedPersonID = person.id
                        } label: {
                            PersonChip(person: person, isSelected: person.id == selectedPersonID)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.bar)

            List {
                Section {
                    ForEach(model.items) { item in
                        itemRow(item)
                    }
                } footer: {
                    Text(selectedPerson == nil
                         ? "Pick a person above, then tap their items. Tap an item with several people selected in turn to share it."
                         : "Tapping toggles this item for \(selectedPerson!.name).")
                }
            }
        }
        .navigationTitle("Assign items")
        .sensoryFeedback(.impact(weight: .light), trigger: model.assignments.count)
        .onAppear {
            if selectedPersonID == nil { selectedPersonID = model.people.first?.id }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if assignedCount < model.items.count {
                    Text("\(assignedCount) of \(model.items.count) items assigned")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                NavigationLink(value: BillStep.tipTax) {
                    Text("Next: Tip & tax")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(assignedCount < model.items.count)
            }
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: LineItem) -> some View {
        let assignees = model.assignees(of: item)
        let isForSelected = selectedPerson.map { model.isAssigned(item: item, to: $0) } ?? false

        Button {
            guard let person = selectedPerson else { return }
            model.toggleAssignment(item: item, person: person)
        } label: {
            HStack {
                Image(systemName: isForSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isForSelected && selectedPerson != nil
                                     ? ChipPalette.color(for: selectedPerson!)
                                     : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .foregroundStyle(.primary)
                    if assignees.count > 1 {
                        Text("Shared \(assignees.count) ways")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                AssigneeStack(people: assignees)
                Text(Money.format(item.priceCents))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .listRowBackground(
            assignees.isEmpty ? Color.yellow.opacity(0.12) : nil
        )
        .accessibilityHint(Text(assignees.isEmpty ? "Unassigned" : "Assigned"))
    }
}
