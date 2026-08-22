import Foundation

/// A track parameterized by the distance travelled from the start.
///
/// This change of viewpoint is what makes everything else possible. Walking a
/// track by hopping from vertex to vertex caps the speed at the vertex spacing:
/// on a track densified every 10 m, you cannot exceed 10 m/s whatever speed is
/// asked for. By reasoning in distance travelled, the position no longer depends
/// at all on how the track happens to be subdivided.
public struct PathGeometry: Sendable {

    /// Vertices, with no consecutive duplicates.
    public let vertices: [Coordinate]
    /// Cumulative distance from the start, for each vertex.
    private let cumulative: [Double]

    public var length: Double { cumulative.last ?? 0 }
    public var count: Int { vertices.count }

    /// - Returns: `nil` if the track does not hold at least two distinct points.
    public init?(_ coordinates: [Coordinate]) {
        var cleaned: [Coordinate] = []
        cleaned.reserveCapacity(coordinates.count)

        for coordinate in coordinates where coordinate.isValid {
            // Two identical points would give a segment of zero length,
            // hence a division by zero when interpolating.
            if let last = cleaned.last, last.distance(to: coordinate) < 0.01 { continue }
            cleaned.append(coordinate)
        }
        guard cleaned.count >= 2 else { return nil }

        var distances: [Double] = [0]
        distances.reserveCapacity(cleaned.count)
        for index in 1..<cleaned.count {
            distances.append(distances[index - 1] + cleaned[index - 1].distance(to: cleaned[index]))
        }

        self.vertices = cleaned
        self.cumulative = distances
    }

    // MARK: - Reading

    /// Position reached after travelling `arcLength` meters.
    public func point(at arcLength: Double) -> Coordinate {
        guard arcLength > 0 else { return vertices[0] }
        guard arcLength < length else { return vertices[vertices.count - 1] }

        let index = segmentIndex(for: arcLength)
        let start = vertices[index]
        let end = vertices[index + 1]
        let into = arcLength - cumulative[index]
        guard into > 0.001 else { return start }

        return start.destination(bearingDegrees: start.bearing(to: end), meters: into)
    }

    /// Course followed at this distance, in degrees from north.
    public func course(at arcLength: Double) -> Double {
        let index = min(segmentIndex(for: max(arcLength, 0)), vertices.count - 2)
        return vertices[index].bearing(to: vertices[index + 1])
    }

    public func arcLength(ofVertex index: Int) -> Double {
        cumulative[min(max(index, 0), cumulative.count - 1)]
    }

    /// Resamples the track onto a regular grid.
    ///
    /// A uniform grid is essential to estimate curvature: on the raw vertices of
    /// a route, spaced anywhere from 5 m to 1 km apart, the computed radius is
    /// nothing but noise.
    public func resample(step: Double) -> [Coordinate] {
        guard step > 0, length > 0 else { return vertices }

        var result: [Coordinate] = []
        var distance = 0.0
        // Stop just short of the end, then place the final point separately.
        // Dividing the length by the step rarely gives a whole count: the
        // length is 1000.0001 m where 1000 is expected, and rounding up would
        // then add a last point coincident with the one before it.
        while distance < length - step * 0.01 {
            result.append(point(at: distance))
            distance += step
        }
        result.append(point(at: length))
        return result
    }

    // MARK: - Internal

    /// Index of the segment holding this distance, by binary search.
    private func segmentIndex(for arcLength: Double) -> Int {
        guard arcLength > 0 else { return 0 }
        var low = 0
        var high = cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle] < arcLength { low = middle + 1 } else { high = middle }
        }
        return max(low - 1, 0)
    }
}
