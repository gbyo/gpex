import Foundation
import SwiftData
import OSLog

/// The composition root.
///
/// A single place that builds the model container, the store and the coordinator, so
/// the `AppDelegate` and the SwiftUI `App` see the same objects regardless of which of
/// them runs first.
final class AppServices {
    static let shared = AppServices()

    let modelContainer: ModelContainer
    let trackStore: TrackStore
    let coordinator: RecordingCoordinator

    private init() {
        let mode = AppLaunchMode.current
        modelContainer = Self.makeContainer(onDisk: mode.usesOnDiskStore)
        trackStore = TrackStore(modelContainer: modelContainer)

        let provider: any LocationUpdatesProvider = mode.usesCoreLocation
            ? CoreLocationUpdatesProvider()
            : TestLocationUpdatesProvider(
                script: mode == .uiTesting ? TestLocationUpdatesProvider.uiTestingScript() : []
            )

        coordinator = RecordingCoordinator(
            trackStore: trackStore,
            markerStore: RecoveryMarkerStore(defaults: Self.makeDefaults(for: mode)),
            provider: provider,
            allowsRestore: mode.restoresInterruptedRecording
        )

        if mode.seedsFixtureData {
            seedFixtureSession()
        }
    }

    private static func makeContainer(onDisk: Bool) -> ModelContainer {
        let schema = Schema([TrackSession.self, TrackPoint.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: !onDisk)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Losing the store must not lose the app. Recording still works; the user
            // simply will not see previous sessions until the problem is resolved.
            Log.persistence.critical("Could not open the store: \(error.localizedDescription, privacy: .public)")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create an in-memory store: \(error)")
            }
        }
    }

    /// UI tests get their own defaults suite so a recovery marker cannot leak between
    /// runs or into the real app's state.
    private static func makeDefaults(for mode: AppLaunchMode) -> UserDefaults {
        guard mode != .normal else { return .standard }
        let suite = UserDefaults(suiteName: "com.example.PhotoTrack.tests") ?? .standard
        suite.removePersistentDomain(forName: "com.example.PhotoTrack.tests")
        return suite
    }

    /// One finished session so UI tests for renaming, corrections, export and delete do
    /// not each have to record one first.
    private func seedFixtureSession() {
        let context = ModelContext(modelContainer)
        let startedAt = Date(timeIntervalSince1970: 1_776_000_000)
        let id = UUID()
        context.insert(
            TrackSession(
                id: id,
                name: "Soccer vs Greenwood",
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(6_420)
            )
        )
        for index in 0..<12 {
            let sample = LocationSample(
                timestamp: startedAt.addingTimeInterval(Double(index) * 30),
                latitude: 41.8781 + Double(index) * 0.0001,
                longitude: -87.6298,
                altitude: 180,
                horizontalAccuracy: 8,
                verticalAccuracy: 5,
                stationary: index > 6
            )
            context.insert(TrackPoint(sessionID: id, sample: sample))
        }
        try? context.save()
    }
}
