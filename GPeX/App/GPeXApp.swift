import SwiftData
import SwiftUI

@main
struct GPeXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: services.coordinator, trackStore: services.trackStore)
        }
        .modelContainer(services.modelContainer)
    }
}
