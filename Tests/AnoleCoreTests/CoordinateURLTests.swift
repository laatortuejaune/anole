import Testing
import Foundation
@testable import AnoleCore

@Suite("Pasted links")
struct CoordinateURLTests {

    func expect(_ url: String, lat: Double, lon: Double, tolerance: Double = 0.0002) {
        guard let parsed = CoordinateParser.parse(url) else {
            Issue.record("'\(url)' was not recognized")
            return
        }
        #expect(abs(parsed.latitude - lat) < tolerance, "\(url) -> lat \(parsed.latitude)")
        #expect(abs(parsed.longitude - lon) < tolerance, "\(url) -> lon \(parsed.longitude)")
    }

    @Test("Google: the named place wins over the camera framing")
    func googlePlaceBeatsCamera() {
        // The camera (@) is at Oakland, the place actually pointed at (!3d/!4d)
        // is at San Francisco. The place is the one that must win.
        expect(
            "https://www.google.com/maps/place/San+Francisco/@37.8044,-122.2712,12z/data=!3m1!4b1!4m6!3d37.7793!4d-122.4193",
            lat: 37.7793, lon: -122.4193
        )
    }

    @Test("Google: the framing is the fallback when there is no place")
    func googleCameraFallback() {
        expect("https://www.google.com/maps/@37.7793,-122.4193,15z", lat: 37.7793, lon: -122.4193)
    }

    @Test("Apple Maps")
    func applePlans() {
        expect("https://maps.apple.com/?ll=48.8584,2.2945", lat: 48.8584, lon: 2.2945)
        expect("https://maps.apple.com/?ll=48.8584,2.2945&q=Tour%20Eiffel", lat: 48.8584, lon: 2.2945)
    }

    @Test("OpenStreetMap: the pinned point")
    func openStreetMapMarker() {
        expect(
            "https://www.openstreetmap.org/?mlat=37.7793&mlon=-122.4193#map=16/37.7793/-122.4193",
            lat: 37.7793, lon: -122.4193
        )
    }

    @Test("OpenStreetMap: the fragment, without mistaking the zoom for the latitude")
    func openStreetMapFragment() {
        // The first number is the zoom (16), not a latitude.
        expect("https://www.openstreetmap.org/#map=16/37.7793/-122.4193", lat: 37.7793, lon: -122.4193)
    }

    @Test("A geo: URI")
    func geoURI() {
        expect("geo:37.7793,-122.4193", lat: 37.7793, lon: -122.4193)
        expect("geo:37.7793,-122.4193?z=15", lat: 37.7793, lon: -122.4193)
    }

    @Test("Coordinates encoded in the text query")
    func queryParameter() {
        expect("https://maps.apple.com/?q=37.7793,-122.4193", lat: 37.7793, lon: -122.4193)
        expect("https://example.com/x?q=37.7793%2C-122.4193", lat: 37.7793, lon: -122.4193)
    }

    @Test("A URL without a coordinate is rejected, not guessed")
    func urlWithoutCoordinates() {
        #expect(CoordinateParser.parse("https://www.google.com/maps/place/Paris") == nil)
        #expect(CoordinateParser.parse("https://example.com/") == nil)
    }

    @Test("An unresolved short link is rejected")
    func shortLink() {
        // maps.app.goo.gl carries no coordinate before redirection.
        #expect(CoordinateParser.parse("https://maps.app.goo.gl/AbCdEf123") == nil)
    }

    @Test("Plain text still goes through the usual parser")
    func plainTextStillWorks() {
        expect("37.7793, -122.4193", lat: 37.7793, lon: -122.4193)
        #expect(CoordinateParser.parse("San Francisco") == nil)
    }
}
