import SwiftUI
import SplitChecksCore

@main
struct SplitChecksApp: App {
    @State private var model = BillFlowModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
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

/// The linear steps after item entry. Item entry is the stack root.
enum BillStep: Hashable {
    case people
    case assign
    case tipTax
    case summary
}
