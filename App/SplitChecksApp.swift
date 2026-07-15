import SwiftUI
import SwiftData
import SplitChecksCore

@main
struct SplitChecksApp: App {
    @State private var model = BillFlowModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .modelContainer(for: SavedBill.self)
    }
}

struct RootView: View {
    @Bindable var model: BillFlowModel

    var body: some View {
        NavigationStack(path: $model.path) {
            ItemsEntryView()
        }
        .environment(model)
    }
}

/// The linear steps after item entry, plus history. Item entry is the
/// stack root.
enum BillStep: Hashable {
    case people
    case assign
    case tipTax
    case summary
    case history
}
