import SwiftUI
import SplitChecksCore

/// Step 4: tax from the receipt, tip by quick buttons or custom amount,
/// and how each should be divided.
struct TipTaxView: View {
    @Environment(BillFlowModel.self) private var model

    private let tipChoices = [18, 20, 25]

    var body: some View {
        @Bindable var model = model
        List {
            Section("Tax") {
                HStack {
                    Text("Tax amount")
                    Spacer()
                    CurrencyField(title: "0.00", cents: $model.taxCents)
                        .frame(width: 100)
                }
                rulePicker("Split tax", selection: $model.taxRule)
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(tipChoices, id: \.self) { percent in
                        Button {
                            model.tipPercent = percent
                        } label: {
                            VStack {
                                Text("\(percent)%")
                                    .fontWeight(.semibold)
                                Text(Money.format(Money.percentage(percent, of: model.subtotalCents)))
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.tipPercent == percent ? .accentColor : .secondary)
                    }
                    Button {
                        model.tipPercent = nil
                    } label: {
                        VStack {
                            Text("Custom")
                                .fontWeight(.semibold)
                            Text(model.tipPercent == nil ? Money.format(model.customTipCents) : "—")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.tipPercent == nil ? .accentColor : .secondary)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                if model.tipPercent == nil {
                    HStack {
                        Text("Custom tip")
                        Spacer()
                        CurrencyField(title: "0.00", cents: $model.customTipCents)
                            .frame(width: 100)
                    }
                }
                rulePicker("Split tip", selection: $model.tipRule)
            } header: {
                Text("Tip")
            } footer: {
                Text("Proportional splits tax and tip by what each person ordered — the fair default. Evenly divides them equally across everyone.")
            }

            Section {
                row("Subtotal", model.subtotalCents)
                row("Tax", model.taxCents)
                row("Tip", model.tipCents)
                row("Total", model.subtotalCents + model.taxCents + model.tipCents, bold: true)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Tip & tax")
        .safeAreaInset(edge: .bottom) {
            NavigationLink(value: BillStep.summary) {
                Text("See the split")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    private func rulePicker(_ title: String, selection: Binding<AllocationRule>) -> some View {
        Picker(title, selection: selection) {
            Text("Proportionally").tag(AllocationRule.proportional)
            Text("Evenly").tag(AllocationRule.even)
        }
        .pickerStyle(.menu)
    }

    private func row(_ label: String, _ cents: Int, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Money.format(cents))
                .monospacedDigit()
        }
        .fontWeight(bold ? .semibold : .regular)
    }
}
