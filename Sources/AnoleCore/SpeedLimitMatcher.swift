import Foundation

/// Flat local projection, used only to measure short distances.
///
/// Over the few tens of kilometres a route spans, treating latitude and
/// longitude as a plane costs a fraction of a metre - far below the tolerance
/// the matcher works at - and turns every point-to-segment test into two
/// subtractions. Doing it on the sphere instead would mean a haversine per
/// candidate segment per node, for no gain whatsoever.
struct LocalPlane {
    private let originLatitude: Double
    private let originLongitude: Double
    private let metersPerDegreeLatitude: Double
    private let metersPerDegreeLongitude: Double

    init(origin: Coordinate) {
        originLatitude = origin.latitude
        originLongitude = origin.longitude
        metersPerDegreeLatitude = 6_371_000 * .pi / 180
        metersPerDegreeLongitude = metersPerDegreeLatitude * cos(origin.latitude * .pi / 180)
    }

    func project(_ coordinate: Coordinate) -> Point {
        Point(
            x: (coordinate.longitude - originLongitude) * metersPerDegreeLongitude,
            y: (coordinate.latitude - originLatitude) * metersPerDegreeLatitude
        )
    }

    struct Point {
        var x: Double
        var y: Double
    }
}

/// Shortest distance from a point to a segment, in metres.
func distance(from point: LocalPlane.Point, toSegment a: LocalPlane.Point, _ b: LocalPlane.Point) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let squaredLength = dx * dx + dy * dy

    // Degenerate segment: the two ends coincide.
    guard squaredLength > 1e-9 else {
        return ((point.x - a.x) * (point.x - a.x) + (point.y - a.y) * (point.y - a.y)).squareRoot()
    }

    // Projection parameter, clamped so the foot stays on the segment.
    var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / squaredLength
    t = min(max(t, 0), 1)

    let footX = a.x + t * dx
    let footY = a.y + t * dy
    return ((point.x - footX) * (point.x - footX) + (point.y - footY) * (point.y - footY)).squareRoot()
}

/// Attaches the road network to a computed route.
///
/// The routing service hands back a bare polyline: no road identity, no speed
/// limit. Recovering them means asking, at regular intervals along the track,
/// which piece of road this point sits on. That is map matching, and nearest
/// segment wins is not enough on its own: at every junction a crossing road
/// passes within a couple of metres of the track, and left to distance alone it
/// takes the match and drops a residential 50 across the middle of a trunk
/// road. The heading gate is what rejects it - a road you cross is not a road
/// you are driving along. Distance still does the rest, in particular against
/// the service road running parallel, which shares the heading and is only ever
/// separated by the metres between them.
public enum SpeedLimitMatcher {

    /// Spacing of the probe points along the track.
    public static let probeSpacing: Double = 25
    /// Beyond this, the segment is considered to be another road entirely.
    public static let matchRadius: Double = 25
    /// Heading difference tolerated between track and segment.
    public static let headingTolerance: Double = 45
    /// A stretch shorter than this is matching noise, not a change of road.
    public static let minimumRunLength: Double = 60
    /// Side of the lookup grid cells.
    static let cellSize: Double = 100

    /// Speed samples covering the track, one per stretch of constant limit.
    ///
    /// Only driving gets samples. A road limit says nothing about the pace of a
    /// pedestrian, and feeding 130 km/h to a walker would not make them faster -
    /// the mode ceiling would flatten every node to the same value and the
    /// calibration would lose the variation it exists to produce.
    public static func samples(
        geometry: PathGeometry,
        segments: [RoadSegment],
        mode: TransportMode
    ) -> [SpeedSample] {
        guard mode == .driving, !segments.isEmpty, geometry.length > 0 else { return [] }

        let plane = LocalPlane(origin: geometry.vertices[0])
        let index = SpatialIndex(segments: segments, plane: plane)

        // One probe every `probeSpacing`, plus the very end of the track.
        var distances: [Double] = []
        var walked = 0.0
        while walked < geometry.length {
            distances.append(walked)
            walked += probeSpacing
        }
        distances.append(geometry.length)

        var matched = [Int?](repeating: nil, count: distances.count)
        for (position, distanceAlong) in distances.enumerated() {
            let point = geometry.point(at: distanceAlong)
            let course = geometry.course(at: distanceAlong)
            matched[position] = index.bestMatch(
                for: plane.project(point),
                course: course,
                segments: segments
            )
        }

        fillGaps(&matched)
        let limits = matched.map { $0.map { segments[$0] } }
        return compress(limits: limits, distances: distances)
    }

    /// Propagates the nearest known match into the unmatched probes.
    ///
    /// Gaps are normal: tunnels, roundabouts drawn as areas, a stretch the
    /// extract simply does not cover. Leaving them empty would carve the trip
    /// into disconnected pieces separated by default-speed holes, which reads
    /// on the map as a car repeatedly losing and regaining its pace.
    static func fillGaps(_ matched: inout [Int?]) {
        var last: Int?
        for position in matched.indices {
            if let value = matched[position] { last = value } else { matched[position] = last }
        }
        var next: Int?
        for position in matched.indices.reversed() {
            if let value = matched[position] { next = value } else { matched[position] = next }
        }
    }

    /// Turns the per-probe matches into contiguous samples, dropping the runs
    /// too short to be a real change of road.
    static func compress(limits: [RoadSegment?], distances: [Double]) -> [SpeedSample] {
        guard limits.count == distances.count, !limits.isEmpty else { return [] }

        struct Run {
            var segment: RoadSegment?
            var start: Double
            var end: Double
        }

        var runs: [Run] = []
        for (position, segment) in limits.enumerated() {
            let distanceAlong = distances[position]
            if var current = runs.last,
               current.segment?.effectiveLimit == segment?.effectiveLimit,
               current.segment?.roadClass == segment?.roadClass {
                current.end = distanceAlong
                runs[runs.count - 1] = current
            } else {
                runs.append(Run(segment: segment, start: distanceAlong, end: distanceAlong))
            }
        }

        // A brief run is almost always a parallel road that won a couple of
        // probes. Absorbing it into the neighbour before it keeps the profile
        // from flickering between two limits every few seconds.
        var cleaned: [Run] = []
        for run in runs {
            if run.end - run.start < minimumRunLength, var previous = cleaned.last {
                previous.end = run.end
                cleaned[cleaned.count - 1] = previous
            } else {
                cleaned.append(run)
            }
        }

        // Each run starts where the last one ended. Built from probe positions
        // alone they would leave one probe spacing uncovered at every change of
        // limit, and the planner treats an uncovered node as having no limit at
        // all - so the car briefly accelerated past the sign in those gaps.
        for index in 1..<max(cleaned.count, 1) where cleaned.count > 1 {
            cleaned[index].start = cleaned[index - 1].end
        }

        return cleaned.compactMap { run in
            guard let segment = run.segment, run.end > run.start else { return nil }
            let limit = segment.effectiveLimit
            return SpeedSample(
                startArcLength: run.start,
                endArcLength: run.end,
                travelSpeed: limit * segment.roadClass.flowFactor,
                legalLimit: limit,
                scaleSensitivity: segment.roadClass.scaleSensitivity,
                limitFidelity: segment.roadClass.limitFidelity
            )
        }
    }
}

// MARK: - Lookup grid

/// Buckets the segments by cell so a probe only tests its own neighbourhood.
///
/// A long route pulls in thousands of segments, and testing every one against
/// every probe is a product that grows fast enough to be felt. The grid brings
/// each probe down to the handful of segments actually near it.
struct SpatialIndex {
    private var cells: [Cell: [Int]] = [:]
    private let plane: LocalPlane

    struct Cell: Hashable {
        var column: Int
        var row: Int
    }

    init(segments: [RoadSegment], plane: LocalPlane) {
        self.plane = plane
        for (position, segment) in segments.enumerated() {
            // Both ends are registered: a segment longer than a cell would
            // otherwise be invisible from the cells it crosses. Segments are
            // short enough in practice that covering the ends is enough.
            for coordinate in [segment.start, segment.end] {
                cells[cell(for: plane.project(coordinate)), default: []].append(position)
            }
        }
    }

    private func cell(for point: LocalPlane.Point) -> Cell {
        Cell(
            column: Int((point.x / SpeedLimitMatcher.cellSize).rounded(.down)),
            row: Int((point.y / SpeedLimitMatcher.cellSize).rounded(.down))
        )
    }

    /// Closest segment whose heading agrees with the track.
    func bestMatch(for point: LocalPlane.Point, course: Double, segments: [RoadSegment]) -> Int? {
        let origin = cell(for: point)
        var best: Int?
        var bestDistance = SpeedLimitMatcher.matchRadius

        for column in (origin.column - 1)...(origin.column + 1) {
            for row in (origin.row - 1)...(origin.row + 1) {
                guard let bucket = cells[Cell(column: column, row: row)] else { continue }
                for position in bucket {
                    let segment = segments[position]
                    // A two-way street is a single way, drawn in one arbitrary
                    // direction. Testing the reverse heading too is what keeps
                    // half of them from being rejected.
                    let bearing = segment.bearing
                    let gap = min(
                        angularDifference(course, bearing),
                        angularDifference(course, (bearing + 180).truncatingRemainder(dividingBy: 360))
                    )
                    guard gap <= SpeedLimitMatcher.headingTolerance else { continue }

                    let candidate = distance(
                        from: point,
                        toSegment: plane.project(segment.start),
                        plane.project(segment.end)
                    )
                    if candidate < bestDistance {
                        bestDistance = candidate
                        best = position
                    }
                }
            }
        }
        return best
    }
}
