import CoreLocation
import Foundation

/// One delivery from `CLLocationUpdate.liveUpdates()`, flattened into a `Sendable`
/// value.
///
/// An update can carry a location, a set of diagnostics, or both. GPeX never
/// infers state from timeouts: every user-visible condition below comes from a flag
/// Core Location set on an update or on a session diagnostic.
nonisolated struct LocationUpdateEvent: Sendable, Equatable {
    /// The fix carried by this update, if it carried one that passed intrinsic validation.
    var sample: LocationSample?

    /// Core Location has stopped delivering because the device is not moving.
    /// Updates resume automatically when it moves again.
    var stationary: Bool = false
    /// Further updates are suspended for a while because the app is limited to
    /// reduced accuracy.
    var accuracyLimited: Bool = false
    /// The device's location can no longer be determined.
    var locationUnavailable: Bool = false
    var authorizationDenied: Bool = false
    var authorizationDeniedGlobally: Bool = false
    var authorizationRestricted: Bool = false
    /// Updates are suspended because the app is not sufficiently in use.
    var insufficientlyInUse: Bool = false
    var serviceSessionRequired: Bool = false
    var authorizationRequestInProgress: Bool = false

    init(sample: LocationSample?) {
        self.sample = sample
        self.stationary = sample?.stationary ?? false
    }

    init(_ update: CLLocationUpdate) {
        self.stationary = update.stationary
        self.accuracyLimited = update.accuracyLimited
        self.locationUnavailable = update.locationUnavailable
        self.authorizationDenied = update.authorizationDenied
        self.authorizationDeniedGlobally = update.authorizationDeniedGlobally
        self.authorizationRestricted = update.authorizationRestricted
        self.insufficientlyInUse = update.insufficientlyInUse
        self.serviceSessionRequired = update.serviceSessionRequired
        self.authorizationRequestInProgress = update.authorizationRequestInProgress
        self.sample = update.location.flatMap {
            LocationSample(location: $0, stationary: update.stationary)
        }
    }

    /// True when nothing about this update prevents recording from continuing.
    var isBlocked: Bool {
        authorizationDenied || authorizationDeniedGlobally || authorizationRestricted
    }
}

/// A diagnostic emitted by a retained `CLServiceSession` or `CLBackgroundActivitySession`.
///
/// These are the authoritative answers to "did the user allow this", "is Precise
/// Location on", and "can the background activity continue". GPeX observes
/// them instead of polling authorization status or guessing from elapsed time.
nonisolated struct SessionDiagnostic: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case serviceSession
        case backgroundActivitySession
    }

    var source: Source
    var authorizationDenied: Bool = false
    var authorizationDeniedGlobally: Bool = false
    var authorizationRestricted: Bool = false
    var insufficientlyInUse: Bool = false
    var serviceSessionRequired: Bool = false
    var authorizationRequestInProgress: Bool = false
    /// Precise Location is off for GPeX. Reported by the service session only.
    var fullAccuracyDenied: Bool = false

    init(source: Source) {
        self.source = source
    }

    init(_ diagnostic: CLServiceSession.Diagnostic) {
        self.source = .serviceSession
        self.authorizationDenied = diagnostic.authorizationDenied
        self.authorizationDeniedGlobally = diagnostic.authorizationDeniedGlobally
        self.authorizationRestricted = diagnostic.authorizationRestricted
        self.insufficientlyInUse = diagnostic.insufficientlyInUse
        self.serviceSessionRequired = diagnostic.serviceSessionRequired
        self.authorizationRequestInProgress = diagnostic.authorizationRequestInProgress
        self.fullAccuracyDenied = diagnostic.fullAccuracyDenied
    }

    init(_ diagnostic: CLBackgroundActivitySession.Diagnostic) {
        self.source = .backgroundActivitySession
        self.authorizationDenied = diagnostic.authorizationDenied
        self.authorizationDeniedGlobally = diagnostic.authorizationDeniedGlobally
        self.authorizationRestricted = diagnostic.authorizationRestricted
        self.insufficientlyInUse = diagnostic.insufficientlyInUse
        self.serviceSessionRequired = diagnostic.serviceSessionRequired
        self.authorizationRequestInProgress = diagnostic.authorizationRequestInProgress
    }
}
