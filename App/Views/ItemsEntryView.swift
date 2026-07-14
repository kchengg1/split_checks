import SwiftUI
import SplitChecksCore

/// Step 1: build the item list by hand. (Milestone 2 adds receipt scanning
/// that lands in this same list for review.)
struct ItemsEntryView: View {
    @Environment(BillFlowModel.self) private var model
    @State private var newName = ""
    @State private var newPriceCents = 0
    @FocusState private var nameFocused: Bool

    var body: some View {
        List {
            Section {
                ForEach(model.items) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(Money.format(item.priceCents))
                            .monospacedDigit()
                            .foregroundStyle(item.priceCents < 0 ? .green : .primary)
                    }
                }
                .onDelete { model.removeItems(at: $0) }

                HStack {
                    TextField("Item name", text: $newName)
                        .focused($nameFocused)
                    CurrencyField(title: "0.00", cents: $newPriceCents)
                        .frame(width: 90)
                        // Recreate the field after each add so its text clears.
                        .id(model.items.count)
                    Button {
                        addItem()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(newPriceCents == 0 && newName.isEmpty)
                    .accessibilityLabel("Add item")
                }
            } header: {
                Text("Items")
            } footer: {
                if model.items.isEmpty {
                    Text("Add each dish from the receipt. Discounts can be negative amounts.")
                }
            }

            if !model.items.isEmpty {
                Section {
                    HStack {
                        Text("Subtotal")
                        Spacer()
                        Text(Money.format(model.subtotalCents))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .navigationTitle("New Bill")
        .navigationDestination(for: BillStep.self) { step in
            switch step {
            case .people: PeopleView()
            case .assign: AssignView()
            case .tipTax: TipTaxView()
            case .summary: SummaryView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink(value: BillStep.people) {
                Text("Next: Who's here?")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.items.isEmpty)
            .padding()
            .background(.bar)
        }
    }

    private func addItem() {
        model.addItem(name: newName, priceCents: newPriceCents)
        newName = ""
        newPriceCents = 0
        nameFocused = true
    }
}
