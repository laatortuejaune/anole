import Foundation
import AnoleCore

/// Reads the road network from OpenStreetMap, through the Overpass API.
///
/// The routing service knows the road it sent you down but does not say what it
/// is; OpenStreetMap knows what every road is but will not route you. Crossing
/// the two is the only way to drive a route at the speed each of its roads
/// actually allows.
///
/// Every failure here is silent by design. Speed limits make the movement
/// better, they are not what makes it work: no network, a slow server, a region
/// nobody has surveyed - the trip must still leave, exactly as it did before
/// this existed.
public actor OverpassSpeedLimits {

    public static let shared = OverpassSpeedLimits()

    /// Public instance, run on donated hardware. Hence the sampling below, the
    /// cache, and the identifying user agent: this is somebody else's server.
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private let userAgent = "Anole/0.1 (+https://github.com/laatortuejaune/anole)"
    /// Past this, the trip leaves without limits rather than keep the user waiting.
    private let timeout: TimeInterval = 10
    /// A public instance under load refuses outright and recovers seconds later.
    /// One retry turns most of those refusals into an answer; a second would
    /// only make the user wait longer for a server that is genuinely down.
    private let attempts = 2
    private let pauseBetweenAttempts: TimeInterval = 1.5
    /// Length of track covered by one query zone, in metres.
    private let zoneLength: Double = 3000
    /// Ceiling on the number of zones; beyond it they are made longer instead.
    private let maximumZones = 24
    /// Margin added around each zone, in metres. Wide enough to hold the road
    /// even where the track cuts a corner.
    private let zoneMargin: Double = 200
    /// Step used to trace the shape of the track inside a zone.
    private let shapeStep: Double = 100

    private var cache: [String: [RoadSegment]] = [:]
    /// Why the last attempt returned nothing. Read by the interface, because a
    /// silent fallback is indistinguishable from a failure.
    public private(set) var lastFailure: String?

    /// Road segments covering the given track. Empty means "unknown", never
    /// "no limit": the caller carries on without them.
    public func segments(along coordinates: [Coordinate]) async -> [RoadSegment] {
        await segments(alongTracks: [coordinates])
    }

    /// Same thing for several candidate routes at once.
    ///
    /// The alternatives to a route share most of their length, so one query
    /// covering all of them costs barely more than a query for one, and spares
    /// the server the two near-identical requests it would otherwise get.
    public func segments(alongTracks tracks: [[Coordinate]]) async -> [RoadSegment] {
        let geometries = tracks.compactMap { PathGeometry($0) }.filter { $0.length > 0 }
        guard !geometries.isEmpty else {
            lastFailure = "no usable track"
            return []
        }

        let zones = self.zones(geometries)
        guard !zones.isEmpty else {
            lastFailure = "no zone to query"
            return []
        }

        let key = cacheKey(for: zones)
        if let cached = cache[key] { return cached }

        var failure = "unreachable"
        for attempt in 1...attempts {
            do {
                let segments = try await fetch(zones: zones)
                cache[key] = segments
                lastFailure = segments.isEmpty ? "no road found in the area" : nil
                return segments
            } catch let error as URLError where error.code == .timedOut {
                failure = "server too slow"
            } catch {
                failure = "unreachable"
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64(pauseBetweenAttempts * 1_000_000_000))
            }
        }
        lastFailure = failure
        return []
    }

    // MARK: - Query

    /// Rectangles covering the track, one per stretch of it.
    ///
    /// The first version asked Overpass for a radius around each of a few
    /// hundred points along the way. It was measured at 21 seconds on a 12 km
    /// trip - one spatial lookup per point - and it silently timed out every
    /// time. A rectangle is a single indexed lookup and answers in about one
    /// second.
    ///
    /// Cutting the track into short stretches rather than taking one rectangle
    /// around the whole thing is what keeps the volume down: a diagonal trip
    /// enclosed in a single box drags in everything either side of it. On the
    /// trip this was measured against, cutting it dropped the answer from 4.2 MB
    /// to 1.1 MB for the same roads.
    private func zones(_ geometries: [PathGeometry]) -> [BoundingBox] {
        let total = geometries.reduce(0) { $0 + $1.length }
        let length = max(zoneLength, total / Double(maximumZones))

        var result: [BoundingBox] = []
        for geometry in geometries {
            var start = 0.0
            while start < geometry.length {
                let end = min(start + length, geometry.length)
                var box: BoundingBox?
                var walked = start
                while walked <= end {
                    let point = geometry.point(at: walked)
                    box = box.map { $0.extended(to: point) } ?? BoundingBox(point)
                    walked += shapeStep
                }
                if let box { result.append(box.padded(by: zoneMargin)) }
                start = end
                if end >= geometry.length { break }
            }
        }
        return result
    }

    struct BoundingBox {
        var minLatitude: Double
        var minLongitude: Double
        var maxLatitude: Double
        var maxLongitude: Double

        init(_ point: Coordinate) {
            minLatitude = point.latitude
            maxLatitude = point.latitude
            minLongitude = point.longitude
            maxLongitude = point.longitude
        }

        func extended(to point: Coordinate) -> BoundingBox {
            var copy = self
            copy.minLatitude = min(minLatitude, point.latitude)
            copy.maxLatitude = max(maxLatitude, point.latitude)
            copy.minLongitude = min(minLongitude, point.longitude)
            copy.maxLongitude = max(maxLongitude, point.longitude)
            return copy
        }

        func padded(by meters: Double) -> BoundingBox {
            let latitudeMargin = meters / 111_320
            // A degree of longitude shrinks with the cosine of the latitude.
            let cosine = max(cos((minLatitude + maxLatitude) / 2 * .pi / 180), 0.05)
            let longitudeMargin = latitudeMargin / cosine
            var copy = self
            copy.minLatitude -= latitudeMargin
            copy.maxLatitude += latitudeMargin
            copy.minLongitude -= longitudeMargin
            copy.maxLongitude += longitudeMargin
            return copy
        }
    }

    private func fetch(zones: [BoundingBox]) async throws -> [RoadSegment] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = query(for: zones).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OverpassError.rejected
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.elements.flatMap(segments(of:))
    }

    /// One union of rectangles, in a single round trip.
    ///
    /// `service` is left out on purpose. Car parks, driveways and delivery lanes
    /// made up more than a third of everything coming back, and a route never
    /// follows one - the matcher would only have had more wrong candidates to
    /// reject. `out geom` returns each way's shape inline, sparing a second
    /// round trip to resolve node references.
    private func query(for zones: [BoundingBox]) -> String {
        let classes = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street"
        let body = zones.map {
            String(
                format: "  way(%.5f,%.5f,%.5f,%.5f)[\"highway\"~\"^(%@)(_link)?$\"];",
                $0.minLatitude, $0.minLongitude, $0.maxLatitude, $0.maxLongitude, classes
            )
        }.joined(separator: "\n")

        return """
        [out:json][timeout:25];
        (
        \(body)
        );
        out geom;
        """
    }

    private func cacheKey(for zones: [BoundingBox]) -> String {
        var hasher = Hasher()
        for zone in zones {
            hasher.combine((zone.minLatitude * 1e4).rounded())
            hasher.combine((zone.minLongitude * 1e4).rounded())
            hasher.combine((zone.maxLatitude * 1e4).rounded())
            hasher.combine((zone.maxLongitude * 1e4).rounded())
        }
        return String(hasher.finalize())
    }

    // MARK: - Decoding

    private enum OverpassError: Error { case rejected }

    private struct Response: Decodable {
        struct Point: Decodable {
            let lat: Double
            let lon: Double
        }
        struct Element: Decodable {
            let tags: [String: String]?
            let geometry: [Point]?
        }
        let elements: [Element]
    }

    /// Cuts one way into the straight pieces the matcher works on.
    private func segments(of element: Response.Element) -> [RoadSegment] {
        guard let tags = element.tags,
              let highway = tags["highway"],
              let parsed = RoadClass.parse(highway: highway),
              let geometry = element.geometry, geometry.count >= 2
        else { return [] }

        // `maxspeed` first, then the country preset the way may carry instead.
        let limit = tags["maxspeed"].flatMap(MaxSpeedTag.parse)
            ?? tags["maxspeed:type"].flatMap(MaxSpeedTag.parse)

        var result: [RoadSegment] = []
        result.reserveCapacity(geometry.count - 1)
        for index in 1..<geometry.count {
            result.append(
                RoadSegment(
                    start: Coordinate(latitude: geometry[index - 1].lat, longitude: geometry[index - 1].lon),
                    end: Coordinate(latitude: geometry[index].lat, longitude: geometry[index].lon),
                    roadClass: parsed.roadClass,
                    isLink: parsed.isLink,
                    taggedLimit: limit,
                    isLit: tags["lit"].map { $0 != "no" } ?? false
                )
            )
        }
        return result
    }
}
