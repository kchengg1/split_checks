import SwiftUI
import CloudKit

/// Accepting an invitation someone sent. A tapped iCloud share link reaches
/// the app through the application delegate, which posts it for whoever is
/// listening.
///
/// Deliberately *not* a scene delegate: a SwiftUI app installs its own, and
/// replacing it via `UISceneConfiguration.delegateClass` leaves the app with
/// no window at all.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let didReceiveShare = Notification.Name("Settled.didReceiveCloudShare")

    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        NotificationCenter.default.post(name: Self.didReceiveShare, object: cloudKitShareMetadata)
    }
}
