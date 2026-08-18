import UIKit
import OSLog

/// The SwiftUI lifecycle alone does not give an early enough, reliable hook for
/// rejoining Core Location after the system has relaunched the process, so GPeX
/// bridges a small `UIApplicationDelegate` in with `@UIApplicationDelegateAdaptor`.
///
/// `didFinishLaunchingWithOptions` is the first point at which the app can tell Core
/// Location it is still interested in the outstanding recording. That has to happen
/// before any scene or view exists, which is exactly what this delegate is for.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // `UIApplication.LaunchOptionsKey.location` is deprecated in iOS 26 precisely
        // because `CLLocationUpdate` replaces it: the way to find out whether Core
        // Location relaunched us is to express interest again and see what arrives, so
        // the launch options are not inspected at all.
        Log.lifecycle.info("Launched with \(launchOptions?.count ?? 0, privacy: .public) launch options")

        // Exported files never outlive the process that made them.
        GPXTemporaryFile.purge()

        // Synchronous, and first: recreate the service session, the background activity
        // session and the live-update stream for any recording that is still open.
        AppServices.shared.coordinator.restoreInterruptedRecordingIfNeeded()

        // Only afterwards. App Intents and MetricKit are both strictly secondary to
        // rejoining an outstanding recording, and neither may delay it.
        AppServices.shared.startProcessServices()

        return true
    }
}
