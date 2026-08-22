import Testing
import Foundation
@testable import AnoleCore

@Suite("GPX tracks")
struct GPXTests {

    let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
      <trk><name>Bay Area walk</name><trkseg>
        <trkpt lat="37.7793" lon="-122.4193"><ele>32.5</ele><time>2000-01-01T00:00:00Z</time></trkpt>
        <trkpt lat="37.7798" lon="-122.4184"><ele>33.0</ele><time>2000-01-01T00:00:30Z</time></trkpt>
        <trkpt lat="37.7806" lon="-122.4175"><time>2000-01-01T00:01:00Z</time></trkpt>
      </trkseg></trk>
    </gpx>
    """

    @Test("Points are read with altitude, timestamp and track name")
    func parsing() throws {
        let track = try GPXDocument.parse(Data(sample.utf8))
        #expect(track.name == "Bay Area walk")
        #expect(track.points.count == 3)
        #expect(abs(track.points[0].coordinate.latitude - 37.7793) < 0.00001)
        #expect(track.points[0].coordinate.altitude == 32.5)
        #expect(track.points[0].timestamp != nil)
    }

    @Test("The recorded duration is derived from the timestamps")
    func recordedDuration() throws {
        let track = try GPXDocument.parse(Data(sample.utf8))
        #expect(track.recordedDuration == 60)
    }

    @Test("A track without timestamps reports no duration")
    func noTimestamps() throws {
        let raw = """
        <?xml version="1.0"?><gpx version="1.1"><trk><trkseg>
        <trkpt lat="37.7793" lon="-122.4193"/><trkpt lat="37.7798" lon="-122.4184"/>
        </trkseg></trk></gpx>
        """
        let track = try GPXDocument.parse(Data(raw.utf8))
        #expect(track.recordedDuration == nil)
        #expect(track.points.count == 2)
    }

    @Test("A GPX with no track point is rejected")
    func emptyTrack() {
        let empty = "<?xml version=\"1.0\"?><gpx version=\"1.1\"><wpt lat=\"1\" lon=\"2\"/></gpx>"
        #expect(throws: GPXDocument.GPXError.self) {
            try GPXDocument.parse(Data(empty.utf8))
        }
    }

    @Test("Broken XML surfaces a clear error")
    func malformed() {
        #expect(throws: (any Error).self) {
            try GPXDocument.parse(Data("<gpx><trk>".utf8))
        }
    }

    @Test("Writing then reading back preserves the coordinates")
    func roundTrip() throws {
        let original = try GPXDocument.parse(Data(sample.utf8))
        let written = GPXDocument.write(original.points, name: original.name)
        let reread = try GPXDocument.parse(Data(written.utf8))

        #expect(reread.name == original.name)
        #expect(reread.points.count == original.points.count)
        for (a, b) in zip(original.points, reread.points) {
            #expect(abs(a.coordinate.latitude - b.coordinate.latitude) < 0.0000001)
            #expect(abs(a.coordinate.longitude - b.coordinate.longitude) < 0.0000001)
        }
    }

    @Test("A track is played like a route, at its original pace")
    func playsAtRecordedPace() throws {
        let track = try GPXDocument.parse(Data(sample.utf8))
        let geometry = try #require(track.geometry)
        // The track covers about 200 m in 60 s, a pace above what a pedestrian
        // holds: its own ceiling must win over the mode ceiling.
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .walking,
            speedCeiling: track.speedCeiling(for: .walking),
            targetDuration: track.recordedDuration
        )
        #expect(abs(schedule.duration - 60) < 2, "duration \(schedule.duration)")
    }

    @Test("A fast track played in walking mode is not throttled")
    func fastTrackNotThrottled() throws {
        let track = try GPXDocument.parse(Data(sample.utf8))
        let ceiling = track.speedCeiling(for: .walking)
        #expect(ceiling != nil, "the mode ceiling would have slowed the track down")
        #expect(ceiling! > TransportMode.walking.maximumSpeed)
    }

    /// The old playback advanced by at least one vertex per tick, which gave
    /// 10 m/s in walking mode instead of 1.4, a factor of seven.
    @Test("Speed no longer depends on the spacing of the points")
    func speedIndependentOfSpacing() throws {
        let origin = Coordinate(latitude: 37.7793, longitude: -122.4193)

        func track(spacing: Double, count: Int) -> PathGeometry {
            var current = origin
            var points = [current]
            for _ in 1..<count {
                current = current.destination(bearingDegrees: 90, meters: spacing)
                points.append(current)
            }
            return PathGeometry(points)!
        }

        let dense = TripSchedule.calibrated(
            geometry: track(spacing: 5, count: 201), mode: .walking, targetDuration: nil
        )
        let sparse = TripSchedule.calibrated(
            geometry: track(spacing: 100, count: 11), mode: .walking, targetDuration: nil
        )
        // Same 1 km length, same pace: the durations must agree.
        #expect(abs(dense.duration - sparse.duration) < 5)

        let averageDense = dense.geometry.length / dense.duration
        #expect(abs(averageDense - TransportMode.walking.defaultSpeed) < 0.3)
    }

    /// The writer used to emit a file its own parser rejects.
    @Test("A name carrying XML characters survives a round trip")
    func escapesNameForXML() throws {
        let points = [
            TrackPoint(coordinate: Coordinate(latitude: 37.7793, longitude: -122.4193), timestamp: Date()),
            TrackPoint(coordinate: Coordinate(latitude: 37.7800, longitude: -122.4180), timestamp: Date()),
        ]
        let xml = GPXDocument.write(points, name: "Rides & <trips>")
        #expect(xml.contains("&amp;"))
        #expect(xml.contains("&lt;trips&gt;"))

        // And the parser takes it straight back.
        let track = try GPXDocument.parse(Data(xml.utf8))
        #expect(track.points.count == 2)
    }
}
