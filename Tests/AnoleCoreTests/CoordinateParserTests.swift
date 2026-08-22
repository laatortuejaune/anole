import Testing
import Foundation
@testable import AnoleCore

@Suite("Coordinate parsing")
struct CoordinateParserTests {

    func expect(_ input: String, lat: Double, lon: Double, tolerance: Double = 0.0002) {
        guard let parsed = CoordinateParser.parse(input) else {
            Issue.record("'\(input)' was not recognized")
            return
        }
        #expect(abs(parsed.latitude - lat) < tolerance, "'\(input)' latitude \(parsed.latitude)")
        #expect(abs(parsed.longitude - lon) < tolerance, "'\(input)' longitude \(parsed.longitude)")
    }

    // MARK: Decimal forms

    @Test("Decimal separated by a comma")
    func decimalComma() {
        expect("37.7793, -122.4193", lat: 37.7793, lon: -122.4193)
        expect("37.7793,-122.4193", lat: 37.7793, lon: -122.4193)
        expect("  48.8584 ,  2.2945  ", lat: 48.8584, lon: 2.2945)
    }

    @Test("Decimal separated by a space")
    func decimalSpace() {
        expect("37.7793 -122.4193", lat: 37.7793, lon: -122.4193)
    }

    @Test("French decimal comma with an explicit separator")
    func frenchDecimalWithSeparator() {
        expect("37,7793; -122,4193", lat: 37.7793, lon: -122.4193)
        expect("37,7793 / -122,4193", lat: 37.7793, lon: -122.4193)
    }

    @Test("French decimal comma recognized from the number of commas")
    func frenchDecimal() {
        // Three commas: two decimal marks plus the separator.
        expect("37,7793, -122,4193", lat: 37.7793, lon: -122.4193)
    }

    // MARK: Degrees, minutes, seconds

    @Test("Degrees minutes seconds with hemispheres")
    func dms() {
        expect("37°46'45.5\"N 122°25'9.5\"W", lat: 37.7793, lon: -122.4193)
        expect("48°51'30.2\"N 2°17'40.2\"E", lat: 48.8584, lon: 2.2945)
    }

    @Test("Degrees and decimal minutes")
    func degreesDecimalMinutes() {
        expect("37°46.76'N 122°25.16'W", lat: 37.7793, lon: -122.4193, tolerance: 0.001)
    }

    @Test("Typographic apostrophes and quotation marks")
    func typographicQuotes() {
        expect("37°46\u{2032}45.5\u{2033}N 122°25\u{2032}9.5\u{2033}W", lat: 37.7793, lon: -122.4193)
    }

    @Test("Non-breaking spaces pasted from a web page")
    func nonBreakingSpaces() {
        expect("37.7793,\u{00A0}-122.4193", lat: 37.7793, lon: -122.4193)
    }

    // MARK: Hemispheres

    @Test("Hemisphere as a suffix on decimal values")
    func hemisphereSuffix() {
        expect("37.7793N, 122.4193W", lat: 37.7793, lon: -122.4193)
        expect("33.8688S, 151.2093E", lat: -33.8688, lon: 151.2093)
    }

    @Test("Hemisphere as a prefix")
    func hemispherePrefix() {
        expect("N37.7793, W122.4193", lat: 37.7793, lon: -122.4193)
    }

    @Test("Order does not matter when the hemispheres are given")
    func hemisphereOrderFree() {
        expect("122.4193W, 37.7793N", lat: 37.7793, lon: -122.4193)
    }

    @Test("'O' for west is treated as 'W'")
    func frenchWest() {
        expect("37.7793N, 122.4193O", lat: 37.7793, lon: -122.4193)
    }

    // MARK: Accepted edge cases

    @Test("Swapped coordinates recovered when the latitude is out of bounds")
    func swappedCoordinates() {
        // 151 cannot be a latitude: this is a lon,lat paste.
        expect("151.2093, -33.8688", lat: -33.8688, lon: 151.2093)
    }

    @Test("The zero point is valid")
    func nullIsland() {
        expect("0, 0", lat: 0, lon: 0)
    }

    @Test("The exact bounds are accepted")
    func bounds() {
        expect("90, 180", lat: 90, lon: 180)
        expect("-90, -180", lat: -90, lon: -180)
    }

    // MARK: What must be rejected

    @Test("An empty input is rejected")
    func empty() {
        #expect(CoordinateParser.parse("") == nil)
        #expect(CoordinateParser.parse("    ") == nil)
    }

    @Test("A place name is not a coordinate")
    func placeName() {
        #expect(CoordinateParser.parse("San Francisco") == nil)
        #expect(CoordinateParser.parse("Paris") == nil)
        #expect(CoordinateParser.parse("12 rue des Lilas") == nil)
    }

    @Test("A lone number is rejected")
    func singleNumber() {
        #expect(CoordinateParser.parse("37.7793") == nil)
    }

    @Test("Two commas without an explicit separator are ambiguous, so rejected")
    func ambiguousCommas() {
        // "37,7793 -122,4193": no honest way to tell a decimal comma from a
        // field separator.
        #expect(CoordinateParser.parse("37,7793 -122,4193") == nil)
    }

    @Test("Out-of-bounds values that cannot be recovered are rejected")
    func outOfBounds() {
        #expect(CoordinateParser.parse("200, 300") == nil)
        #expect(CoordinateParser.parse("91, 181") == nil)
    }

    @Test("Invalid minutes or seconds are rejected")
    func invalidSexagesimal() {
        #expect(CoordinateParser.parse("37°75'00\"N 122°25'00\"W") == nil)
        #expect(CoordinateParser.parse("37°46'99\"N 122°25'00\"W") == nil)
    }

    @Test("Two hemispheres on the same axis are rejected")
    func duplicateHemisphere() {
        #expect(CoordinateParser.parse("37.7793N, 122.4193N") == nil)
    }
}
