import CoreLocation
import Foundation
import OSLog

/// The Core Location seam.
///
/// Everything PhotoTrack needs from Core Location goes through this protocol, so the
/// recording logic can be exercised with deterministic scripted input and no GPS
/// hardware. There is exactly one production implementation
/// (`CoreLocationUpdatesProvider`) and one test implementation
/// (`TestLocationUpdatesProvider`).
protocol LocationUpdatesProvider: Sendable {
    /// The stream of live updates. Each call starts a fresh consumption of
    /// `CLLocationUpdate.liveUpdates()`; the caller must guarantee only one is alive
    /// per recording.
    nonisolated func liveUpdates() -> AsyncThrowingStream<LocationUpdateEvent, any Error>

    /// Creates the explicit location sessions that authorize and sustain a recording.
    /// The returned object must be retained for the entire recording.
    func beginSessions() -> any LocationSessionHandles
}

/// The explicit Core Location sessions backing one recording.
///
/// The service session drives authorization (When In Use plus temporary full
/// accuracy) and the background activity session keeps the app eligible to receive
/// updates while it is not in the foreground. Both are owned by the recording and
/// invalidated only when the user stops it.
protocol LocationSessionHandles: AnyObject {
    /// Merged diagnostics from both sessions. Finishes when the sessions are invalidated.
    func diagnostics() -> AsyncStream<SessionDiagnostic>

    /// Releases both sessions. Safe to call more than once.
    func invalidate()
}

// MARK: - Production

/// Production adapter around `CLLocationUpdate.liveUpdates()`.
nonisolated struct CoreLocationUpdatesProvider: LocationUpdatesProvider {
    /// The purpose key in `NSLocationTemporaryUsageDescriptionDictionary`.
    static let fullAccuracyPurposeKey = "PhotoTracking"

    /// The one place the live-update configuration is chosen.
    ///
    /// `.default` lets Core Location manage power for a device that spends most of a
    /// game standing still. Field testing may show that short sideline relocations are
    /// detected too slowly, in which case this single property is the thing to change
    /// to `.fitness` and re-measure. It is deliberately not a user setting.
    ///
    /// Computed rather than stored because `LiveConfiguration` is not `Sendable`.
    static var liveConfiguration: CLLocationUpdate.LiveConfiguration { .default }

    func liveUpdates() -> AsyncThrowingStream<LocationUpdateEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(Self.liveConfiguration) {
                        continuation.yield(LocationUpdateEvent(update))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func beginSessions() -> any LocationSessionHandles {
        CoreLocationSessionHandles()
    }
}

/// Holds the live `CLServiceSession` and `CLBackgroundActivitySession`.
///
/// Creating the service session is what prompts the user for When In Use
/// authorization and for temporary full accuracy — PhotoTrack never calls
/// `requestWhenInUseAuthorization()` directly and never asks for Always.
final class CoreLocationSessionHandles: LocationSessionHandles {
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?

    init() {
        // Order matters: authorize first, then declare the background activity.
        serviceSession = CLServiceSession(
            authorization: .whenInUse,
            fullAccuracyPurposeKey: CoreLocationUpdatesProvider.fullAccuracyPurposeKey
        )
        backgroundSession = CLBackgroundActivitySession()
        Log.recording.info("Created CLServiceSession and CLBackgroundActivitySession")
    }

    func diagnostics() -> AsyncStream<SessionDiagnostic> {
        let service = serviceSession
        let background = backgroundSession
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    if let service {
                        group.addTask {
                            // `Diagnostics` is not Sendable, so it is created and consumed
                            // entirely inside this child task from the Sendable session.
                            do {
                                for try await diagnostic in service.diagnostics {
                                    continuation.yield(SessionDiagnostic(diagnostic))
                                }
                            } catch {
                                Log.recording.error("Service session diagnostics ended: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                    if let background {
                        group.addTask {
                            do {
                                for try await diagnostic in background.diagnostics {
                                    continuation.yield(SessionDiagnostic(diagnostic))
                                }
                            } catch {
                                Log.recording.error("Background activity diagnostics ended: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func invalidate() {
        // Idempotent: releasing the references twice is harmless, and a stopped
        // recording must never leave a background activity session alive.
        serviceSession?.invalidate()
        backgroundSession?.invalidate()
        if serviceSession != nil || backgroundSession != nil {
            Log.recording.info("Invalidated CLServiceSession and CLBackgroundActivitySession")
        }
        serviceSession = nil
        backgroundSession = nil
    }
}
