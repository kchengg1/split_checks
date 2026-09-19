import SwiftUI
import SwiftData
import CloudKit
import SettledCore

@main
struct SettledApp: App {
    // An app delegate, purely so an accepted iCloud share invitation
    // reaches the app.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = BillFlowModel()
    @State private var cloud = CloudSyncEngine()
    private let container: ModelContainer

    init() {
        let screenshots = DemoData.isScreenshotRun
        // Screenshot runs use a throwaway in-memory store seeded with demo
        // data; real launches use the persistent store as before.
        let configuration = ModelConfiguration(isStoredInMemoryOnly: screenshots)
        let container = try! ModelContainer(for: SavedBill.self, SavedTrip.self, SavedPerson.self,
                                            configurations: configuration)
        if screenshots {
            DemoData.seed(into: container.mainContext)
            _model = State(initialValue: DemoData.receiptModel())
        }
        self.container = container
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .environment(cloud)
        }
        .modelContainer(container)
    }
}

/// Four tabs, each its own navigation stack so switching preserves where
/// you were: split a single receipt, track groups, see what changed, and
/// settings (who you are, the people directory).
struct RootView: View {
    @Bindable var model: BillFlowModel
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CloudSyncEngine.self) private var cloud
    @AppStorage(Me.onboardedKey) private var onboarded = false
    @AppStorage(Me.defaultsKey) private var meIDString = ""
    @State private var showingOnboarding = false
    @State private var incoming: GroupDocument?
    @State private var openFailed = false

    var body: some View {
        TabView {
            NavigationStack(path: $model.path) {
                ItemsEntryView()
            }
            .environment(model)
            .tabItem { Label("Receipt", systemImage: "doc.viewfinder") }

            NavigationStack {
                GroupsListView()
            }
            .tabItem { Label("Groups", systemImage: "person.3.fill") }

            NavigationStack {
                FriendsView()
            }
            .tabItem { Label("Friends", systemImage: "person.2.fill") }

            NavigationStack {
                ActivityView()
            }
            .tabItem { Label("Activity", systemImage: "clock.fill") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .task {
            PeopleDirectory.backfillIfNeeded(in: context)
            materializeRecurring()
            if !onboarded { showingOnboarding = true }
            await GroupSyncCoordinator.syncAll(engine: cloud, context: context)
        }
        // No server generates recurring expenses or pushes changes; the app
        // does both whenever it comes to the foreground.
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            materializeRecurring()
            Task { await GroupSyncCoordinator.syncAll(engine: cloud, context: context) }
        }
        // Someone tapped an invitation to a shared group.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.didReceiveShare)) { notification in
            guard let metadata = notification.object as? CKShare.Metadata else { return }
            Task {
                try? await cloud.accept(metadata)
                await GroupSyncCoordinator.syncAll(engine: cloud, context: context)
            }
        }
        // Dismissing by any route counts as "asked once"; Settings can
        // always set it later.
        .sheet(isPresented: $showingOnboarding, onDismiss: { onboarded = true }) {
            MeOnboardingView()
        }
        // A `.settled` file tapped in Messages, Files, or AirDrop.
        .onOpenURL { url in
            if let document = GroupSharing.read(from: url) {
                incoming = document
            } else {
                openFailed = true
            }
        }
        .sheet(item: $incoming) { document in
            ImportGroupSheet(document: document)
        }
        .alert("Couldn't open that file", isPresented: $openFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It isn't a Settled group file, or it's from a newer version of the app.")
        }
    }
}

extension RootView {
    private func materializeRecurring() {
        let groups = (try? context.fetch(FetchDescriptor<SavedTrip>())) ?? []
        for saved in groups {
            var group = saved.group
            if group.materializeRecurring(by: Me.parse(meIDString)) > 0 {
                saved.update(from: group)
            }
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
