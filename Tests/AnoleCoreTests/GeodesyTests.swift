import Testing
import Foundation
@testable import AnoleCore

@Suite("Geodesy")
struct GeodesyTests {

    // San Francisco -> Half Moon Bay, ~30 km as the crow flies.
    let sanFrancisco = Coordinate(latitude: 37.7793, longitude: -122.4193)
    let halfMoonBay = Coordinate(latitude: 37.4636, longitude: -122.4286)

    @Test("The distance matches what is measured on the ground")
    func distance() {
        let meters = sanFrancisco.distance(to: halfMoonBay)
        #expect(meters > 32_000 && meters < 36_000)
    }

    @Test("The distance is symmetric")
    func distanceSymmetry() {
        let ab = sanFrancisco.distance(to: halfMoonBay)
        let ba = halfMoonBay.distance(to: sanFrancisco)
        #expect(abs(ab - ba) < 0.001)
    }

    @Test("Moving then measuring gives back the distance travelled")
    func destinationRoundTrip() {
        let target = sanFrancisco.destination(bearingDegrees: 90, meters: 1000)
        let measured = sanFrancisco.distance(to: target)
        #expect(abs(measured - 1000) < 1)
    }

    @Test("A due east bearing produces movement to the east")
    func bearingEast() {
        let target = sanFrancisco.destination(bearingDegrees: 90, meters: 5000)
        #expect(target.longitude > sanFrancisco.longitude)
        #expect(abs(target.latitude - sanFrancisco.latitude) < 0.001)
    }

    @Test("A due north bearing produces movement to the north")
    func bearingNorth() {
        let target = sanFrancisco.destination(bearingDegrees: 0, meters: 5000)
        #expect(target.latitude > sanFrancisco.latitude)
        #expect(abs(target.longitude - sanFrancisco.longitude) < 0.001)
    }

    @Test("Longitude stays within bounds when crossing the antimeridian")
    func antimeridian() {
        let nearLine = Coordinate(latitude: 0, longitude: 179.99)
        let crossed = nearLine.destination(bearingDegrees: 90, meters: 5000)
        #expect(crossed.longitude >= -180 && crossed.longitude <= 180)
        #expect(crossed.longitude < 0) // we crossed to the other side
    }

    @Test("Out-of-bounds coordinates are rejected")
    func validation() {
        #expect(Coordinate(latitude: 37.7793, longitude: -122.4193).isValid)
        #expect(!Coordinate(latitude: 91, longitude: 0).isValid)
        #expect(!Coordinate(latitude: 0, longitude: 181).isValid)
    }

    @Test("CLI formatting yields two usable arguments")
    func cliFormatting() {
        let args = sanFrancisco.cliArguments
        #expect(args.count == 2)
        #expect(Double(args[0]) != nil)
        #expect(Double(args[1]) != nil)
    }
}

@Suite("Mock backend")
struct MockBackendTests {

    @Test("The backend refuses a location before preparation")
    func requiresPreparation() async {
        let backend = MockBackend()
        await #expect(throws: BackendError.self) {
            try await backend.setLocation(Coordinate(latitude: 37.7793, longitude: -122.4193))
        }
    }

    @Test("The full cycle works and reports the steps in order")
    func fullCycle() async throws {
        let backend = MockBackend()
        let device = try await backend.discoverDevices()[0]

        let box = StepBox()
        try await backend.prepare(device: device) { step in box.append(step) }

        #expect(box.steps.first == .checkingTooling)
        #expect(box.steps.last == .ready)

        let position = Coordinate(latitude: 37.7793, longitude: -122.4193)
        try await backend.setLocation(position)
        #expect(backend.lastLocation == position)

        try await backend.clearLocation()
        #expect(backend.lastLocation == nil)
    }

    @Test("An invalid coordinate is rejected")
    func rejectsInvalid() async throws {
        let backend = MockBackend()
        let device = try await backend.discoverDevices()[0]
        try await backend.prepare(device: device) { _ in }

        await #expect(throws: BackendError.self) {
            try await backend.setLocation(Coordinate(latitude: 200, longitude: 0))
        }
    }
}

/// Small thread-safe collector to observe the preparation steps.
final class StepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PreparationStep] = []

    var steps: [PreparationStep] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ step: PreparationStep) {
        lock.lock(); defer { lock.unlock() }
        storage.append(step)
    }
}

@Suite("Device detection")
struct DeviceListingTests {

    /// Representative listing output: the same device shows up twice,
    /// once over the network and once over the cable.
    let realOutput = """
    [
        {
            "BuildVersion": "24A5408d",
            "ConnectionType": "Network",
            "DeviceClass": "iPhone",
            "DeviceName": "Test iPhone",
            "Identifier": "00008030-001A2B3C4D5E6F70",
            "ProductType": "iPhone17,3",
            "ProductVersion": "27.0",
            "UniqueDeviceID": "00008030-001A2B3C4D5E6F70"
        },
        {
            "BuildVersion": "24A5408d",
            "ConnectionType": "USB",
            "DeviceClass": "iPhone",
            "DeviceName": "Test iPhone",
            "Identifier": "00008030-001A2B3C4D5E6F70",
            "ProductType": "iPhone17,3",
            "ProductVersion": "27.0",
            "UniqueDeviceID": "00008030-001A2B3C4D5E6F70"
        }
    ]
    """

    @Test("The network and cable duplicate is merged, preferring USB")
    func deduplicatesPreferringUSB() throws {
        let devices = try DeviceListing.parse(realOutput)
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device.connectionKind == .usb)
        #expect(device.udid == "00008030-001A2B3C4D5E6F70")
        #expect(device.osVersion == "27.0")
        #expect(device.productType == "iPhone17,3")
        #expect(device.name == "Test iPhone")
    }

    @Test("The major iOS version is extracted")
    func majorVersion() throws {
        let device = try #require(try DeviceListing.parse(realOutput).first)
        #expect(device.majorOSVersion == 27)
    }

    @Test("An empty list yields no device")
    func emptyList() throws {
        #expect(try DeviceListing.parse("[]").isEmpty)
    }

    @Test("Unreadable output surfaces an error rather than staying silent")
    func garbage() {
        #expect(throws: (any Error).self) {
            try DeviceListing.parse("not json")
        }
    }
}

@Suite("Bearing normalization")
struct BearingNormalizationTests {

    let origin = Coordinate(latitude: 37.7793, longitude: -122.4193)

    @Test("The four cardinal points fall within [0, 360)")
    func cardinalPoints() {
        let cases: [(Double, Double)] = [(0, 0), (90, 90), (180, 180), (270, 270)]
        for (asked, expected) in cases {
            let target = origin.destination(bearingDegrees: asked, meters: 2000)
            let measured = origin.bearing(to: target)
            #expect(measured >= 0 && measured < 360)
            // Circular comparison: north comes out at 359.999 degrees, which is
            // correct. A raw subtraction would see a 360 degree error there.
            #expect(angularDifference(measured, expected) < 0.5, "bearing \(asked) measured \(measured)")
        }
    }

    @Test("A westward bearing is 270 and not -90")
    func westIsNotNegative() {
        let west = origin.destination(bearingDegrees: 270, meters: 5000)
        let measured = origin.bearing(to: west)
        #expect(measured > 269 && measured < 271)
    }

    @Test("No bearing is negative, whatever the direction")
    func neverNegative() {
        for degrees in stride(from: 0.0, to: 360.0, by: 15.0) {
            let target = origin.destination(bearingDegrees: degrees, meters: 1000)
            #expect(origin.bearing(to: target) >= 0, "bearing \(degrees) returns a negative")
        }
    }
}

@Suite("Angular difference")
struct AngularDifferenceTests {

    @Test("The difference is symmetric and capped at 180")
    func symmetryAndBounds() {
        #expect(angularDifference(10, 350) == 20)
        #expect(angularDifference(350, 10) == 20)
        #expect(angularDifference(0, 180) == 180)
        #expect(angularDifference(90, 270) == 180)
    }

    @Test("Crossing north does not create a false large difference")
    func acrossNorth() {
        // The exact trap that made the cardinal points test fail.
        #expect(angularDifference(359.999, 0) < 0.01)
        #expect(angularDifference(1, 359) == 2)
    }

    @Test("Two identical bearings give a zero difference")
    func identical() {
        #expect(angularDifference(42, 42) == 0)
    }

    @Test("A right-angle turn is measured at 90 degrees")
    func rightAngle() {
        #expect(angularDifference(45, 135) == 90)
        #expect(angularDifference(315, 45) == 90)
    }

    /// Rounding pushes `a` above 1 for near-antipodal pairs and sqrt(1-a) goes
    /// NaN — which then spreads silently: the duplicate filter lets the point
    /// through, the track length becomes NaN, and the trip never ends.
    @Test("Near-antipodal points give a real distance, never NaN")
    func antipodalDistance() {
        let pairs: [(Coordinate, Coordinate)] = [
            (Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 180)),
            (Coordinate(latitude: 45, longitude: 0), Coordinate(latitude: -45, longitude: 180)),
            (Coordinate(latitude: 90, longitude: 0), Coordinate(latitude: -90, longitude: 0)),
            (Coordinate(latitude: 1e-9, longitude: 0), Coordinate(latitude: -1e-9, longitude: 180)),
        ]
        for (a, b) in pairs {
            let d = a.distance(to: b)
            #expect(!d.isNaN)
            #expect(d > 19_000_000 && d < 21_000_000)
        }
    }
}
