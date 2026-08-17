import CoreLocation
import Foundation
import Testing
@testable import GPeX

@Suite("Raw point acceptance")
nonisolated struct LocationSampleTests {
    private func location(
        latitude: Double = 41.8781,
        longitude: Double = -87.6298,
        altitude: Double = 181,
        horizontalAccuracy: Double = 8,
        verticalAccuracy: Double = 4,
        course: Double = 90,
        courseAccuracy: Double = 5,
        speed: Double = 1.4,
        speedAccuracy: Double = 0.5
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: course,
            courseAccuracy: courseAccuracy,
            speed: speed,
            speedAccuracy: speedAccuracy,
            timestamp: testBase
        )
    }

    @Test("A complete fix is accepted with every field")
    func acceptsCompleteFix() throws {
        let sample = try #require(LocationSample(location: location(), stationary: true))
        #expect(sample.latitude == 41.8781)
        #expect(sample.longitude == -87.6298)
        #expect(sample.altitude == 181)
        #expect(sample.horizontalAccuracy == 8)
        #expect(sample.verticalAccuracy == 4)
        #expect(sample.speed == 1.4)
        #expect(sample.course == 90)
        #expect(sample.stationary)
    }

    @Test("Invalid coordinates are rejected")
    func rejectsInvalidCoordinates() {
        #expect(LocationSample(location: location(latitude: 91), stationary: false) == nil)
        #expect(LocationSample(location: location(longitude: 181), stationary: false) == nil)
        #expect(LocationSample(location: location(latitude: .nan), stationary: false) == nil)
        #expect(LocationSample(location: location(longitude: .infinity), stationary: false) == nil)
    }

    @Test("A negative horizontal accuracy is rejected")
    func rejectsNegativeHorizontalAccuracy() {
        #expect(LocationSample(location: location(horizontalAccuracy: -1), stationary: false) == nil)
    }

    @Test("Altitude is stored only when its accuracy is valid")
    func altitudeRequiresValidVerticalAccuracy() throws {
        let invalid = try #require(LocationSample(location: location(verticalAccuracy: -1), stationary: false))
        #expect(invalid.altitude == nil)
        #expect(invalid.verticalAccuracy == nil)

        let zeroAccuracy = try #require(LocationSample(location: location(verticalAccuracy: 0), stationary: false))
        #expect(zeroAccuracy.altitude == nil)

        let valid = try #require(LocationSample(location: location(verticalAccuracy: 2), stationary: false))
        #expect(valid.altitude == 181)
    }

    @Test("Speed and course are stored only when Core Location considers them valid")
    func speedAndCourseRequireValidity() throws {
        let noSpeed = try #require(LocationSample(location: location(speed: -1), stationary: false))
        #expect(noSpeed.speed == nil)

        let untrustedSpeed = try #require(LocationSample(location: location(speedAccuracy: -1), stationary: false))
        #expect(untrustedSpeed.speed == nil)

        let noCourse = try #require(LocationSample(location: location(course: -1), stationary: false))
        #expect(noCourse.course == nil)

        let untrustedCourse = try #require(LocationSample(location: location(courseAccuracy: -1), stationary: false))
        #expect(untrustedCourse.course == nil)
    }

    @Test("A mediocre fix is kept, not discarded")
    func keepsMediocreFix() throws {
        let sample = try #require(LocationSample(location: location(horizontalAccuracy: 140), stationary: false))
        #expect(sample.quality == .poor)
        #expect(sample.horizontalAccuracy == 140)
    }

    @Test("Absent speed is not treated as evidence of movement")
    func absentSpeedIsNotMovement() {
        #expect(sample(0, speed: nil).indicatesMovement(fasterThan: 1) == false)
        #expect(sample(0, speed: 0.4).indicatesMovement(fasterThan: 1) == false)
        #expect(sample(0, speed: 2.2).indicatesMovement(fasterThan: 1) == true)
    }
}
