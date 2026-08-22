import Foundation

/// A track point, with its original timestamp when the file provides one.
public struct TrackPoint: Hashable, Sendable {
    public var coordinate: Coordinate
    public var timestamp: Date?

    public init(coordinate: Coordinate, timestamp: Date? = nil) {
        self.coordinate = coordinate
        self.timestamp = timestamp
    }
}

/// A track loaded from a GPX file.
public struct GPXTrack: Sendable {
    public var name: String
    public var points: [TrackPoint]

    public var geometry: PathGeometry? { PathGeometry(points.map(\.coordinate)) }

    /// Real duration of the track, when the points carry timestamps.
    ///
    /// A recorded track carries its own pace: honoring it makes playback far
    /// more faithful than pasting a theoretical speed onto it.
    public var recordedDuration: TimeInterval? {
        let dates = points.compactMap(\.timestamp).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let duration = last.timeIntervalSince(first)
        return duration > 1 ? duration : nil
    }

    /// Real average speed of the track, in m/s.
    public var recordedAverageSpeed: Double? {
        guard let duration = recordedDuration, let geometry, duration > 0 else { return nil }
        return geometry.length / duration
    }

    /// Ceiling to hand the backend so it holds the original pace.
    ///
    /// A track recorded in a car, played back in walking mode, must not be
    /// capped at 2 m/s: the pace of the file wins over the chosen mode.
    public func speedCeiling(for mode: TransportMode) -> Double? {
        guard let average = recordedAverageSpeed else { return nil }
        let needed = average * 1.6
        return needed > mode.maximumSpeed ? needed : nil
    }
}

/// Reading and writing of GPX tracks.
///
/// Only what is needed is handled: `trkpt` (track points) and `rtept` (route
/// points). Standalone `wpt` waypoints are ignored, they do not describe a
/// movement.
public enum GPXDocument {

    public static func load(from url: URL) throws -> GPXTrack {
        let data = try Data(contentsOf: url)
        var track = try parse(data)
        if track.name.isEmpty {
            track.name = url.deletingPathExtension().lastPathComponent
        }
        return track
    }

    public static func parse(_ data: Data) throws -> GPXTrack {
        let parser = XMLParser(data: data)
        let delegate = GPXParserDelegate()
        parser.delegate = delegate

        guard parser.parse() else {
            throw GPXError.malformed(parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        guard !delegate.points.isEmpty else {
            throw GPXError.noTrackPoints
        }
        return GPXTrack(name: delegate.trackName, points: delegate.points)
    }

    public static func write(_ points: [TrackPoint], name: String = "Anole") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Anole" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for point in points {
            let lat = String(format: "%.7f", point.coordinate.latitude)
            let lon = String(format: "%.7f", point.coordinate.longitude)
            xml += "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
            if let altitude = point.coordinate.altitude {
                xml += "        <ele>\(String(format: "%.2f", altitude))</ele>\n"
            }
            if let timestamp = point.timestamp {
                xml += "        <time>\(formatter.string(from: timestamp))</time>\n"
            }
            xml += "      </trkpt>\n"
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>

        """
        return xml
    }

    public enum GPXError: Error, LocalizedError {
        case malformed(String)
        case noTrackPoints

        public var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "Unreadable GPX: \(detail)"
            case .noTrackPoints: return "This GPX contains no track point."
            }
        }
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var points: [TrackPoint] = []
    var trackName = ""

    private var pendingCoordinate: Coordinate?
    private var pendingTimestamp: Date?
    private var currentText = ""
    private var insideTrack = false

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentText = ""
        if elementName == "trk" || elementName == "rte" { insideTrack = true }
        guard elementName == "trkpt" || elementName == "rtept" else { return }
        guard
            let latText = attributeDict["lat"], let lat = Double(latText),
            let lonText = attributeDict["lon"], let lon = Double(lonText)
        else { return }

        pendingCoordinate = Coordinate(latitude: lat, longitude: lon)
        pendingTimestamp = nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentText = ""

        switch elementName {
        case "name":
            // Only the name of the track is of interest, not that of a point.
            if insideTrack, trackName.isEmpty, pendingCoordinate == nil { trackName = text }
        case "ele":
            if let elevation = Double(text) { pendingCoordinate?.altitude = elevation }
        case "time":
            pendingTimestamp = isoFormatter.date(from: text) ?? isoFormatterNoFraction.date(from: text)
        case "trkpt", "rtept":
            if let coordinate = pendingCoordinate, coordinate.isValid {
                points.append(TrackPoint(coordinate: coordinate, timestamp: pendingTimestamp))
            }
            pendingCoordinate = nil
            pendingTimestamp = nil
        default:
            break
        }
    }
}
