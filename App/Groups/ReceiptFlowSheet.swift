import SwiftUI
import SettledCore

/// The receipt flow (scan → items → people → assign → tip & tax → summary)
/// presented from a group. The model carries the group target, so the
/// summary ends with "Add to <group>" instead of saving to history.
struct ReceiptFlowSheet: View {
    @Bindable var model: BillFlowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $model.path) {
            ItemsEntryView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .environment(model)
        .tint(Theme.accent)
    }
}
