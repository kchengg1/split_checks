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
        .modelContainer(for: [SavedBill.self, SavedTrip.self])
    }
}

/// Two modes side by side: split a single receipt, or track a trip's shared
/// expenses. Each is its own navigation stack so switching tabs preserves
/// where you were.
struct RootView: View {
    @Bindable var model: BillFlowModel

    var body: some View {
        TabView {
            NavigationStack(path: $model.path) {
                ItemsEntryView()
            }
            .environment(model)
            .tabItem { Label("Receipt", systemImage: "doc.viewfinder") }

            NavigationStack {
                TripsListView()
            }
            .tabItem { Label("Trips", systemImage: "airplane") }
        }
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
