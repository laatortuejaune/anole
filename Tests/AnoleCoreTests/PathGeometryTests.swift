import Testing
import Foundation
@testable import AnoleCore

@Suite("Path geometry")
struct PathGeometryTests {

    let start = Coordinate(latitude: 37.7793, longitude: -122.4193)

    /// Straight line heading east, `count` points spaced `spacing` meters apart.
    func line(count: Int, spacing: Double) -> [Coordinate] {
        var current = start
        var points = [current]
        for _ in 1..<count {
            current = current.destination(bearingDegrees: 90, meters: spacing)
            points.append(current)
        }
        return points
    }

    @Test("A path with fewer than two distinct points is rejected")
    func rejectsDegenerate() {
        #expect(PathGeometry([]) == nil)
        #expect(PathGeometry([start]) == nil)
        // The same point twice does not make a path.
        #expect(PathGeometry([start, start]) == nil)
    }

    @Test("Consecutive duplicates are dropped")
    func removesDuplicates() throws {
        let far = start.destination(bearingDegrees: 90, meters: 100)
        let geometry = try #require(PathGeometry([start, start, far, far, far]))
        #expect(geometry.count == 2)
        #expect(abs(geometry.length - 100) < 0.5)
    }

    @Test("The length is the sum of the segments")
    func length() throws {
        let geometry = try #require(PathGeometry(line(count: 11, spacing: 100)))
        #expect(abs(geometry.length - 1000) < 1)
    }

    @Test("The endpoints are exact and overshoots are clamped")
    func endpoints() throws {
        let points = line(count: 11, spacing: 100)
        let geometry = try #require(PathGeometry(points))

        #expect(geometry.point(at: 0) == points[0])
        #expect(geometry.point(at: -50) == points[0])
        #expect(geometry.point(at: geometry.length) == points[10])
        #expect(geometry.point(at: 99_999) == points[10])
    }

    @Test("The position halfway along a segment is interpolated correctly")
    func interpolates() throws {
        let geometry = try #require(PathGeometry(line(count: 3, spacing: 100)))
        let middle = geometry.point(at: 50)
        #expect(abs(start.distance(to: middle) - 50) < 0.5)
    }

    /// THE test that justifies this whole class: the position read at a given
    /// distance must not depend on how finely the path is subdivided.
    @Test("The position does not depend on the vertex spacing")
    func independentOfVertexSpacing() throws {
        let coarse = try #require(PathGeometry(line(count: 3, spacing: 500)))
        let fine = try #require(PathGeometry(line(count: 101, spacing: 10)))

        for distance in stride(from: 0.0, through: 1000.0, by: 50.0) {
            let a = coarse.point(at: distance)
            let b = fine.point(at: distance)
            #expect(a.distance(to: b) < 1.0, "deviation at \(distance) m")
        }
    }

    @Test("The course follows the direction of the path")
    func course() throws {
        let geometry = try #require(PathGeometry(line(count: 5, spacing: 100)))
        #expect(angularDifference(geometry.course(at: 150), 90) < 1)
    }

    @Test("Resampling produces a regular grid")
    func resample() throws {
        let geometry = try #require(PathGeometry(line(count: 3, spacing: 500)))
        let grid = geometry.resample(step: 25)

        #expect(grid.count == 41)
        for index in 0..<(grid.count - 2) {
            let gap = grid[index].distance(to: grid[index + 1])
            #expect(abs(gap - 25) < 0.5, "irregular step at index \(index)")
        }
        #expect(grid.last!.distance(to: geometry.point(at: geometry.length)) < 0.5)
    }

    @Test("Resampling a very short path stays consistent")
    func resampleShort() throws {
        let geometry = try #require(PathGeometry(line(count: 2, spacing: 5)))
        let grid = geometry.resample(step: 25)
        #expect(grid.count >= 2)
        #expect(grid.first!.distance(to: geometry.point(at: 0)) < 0.1)
    }

    @Test("The segment lookup stays correct on a heavily subdivided path")
    func manyVertices() throws {
        let geometry = try #require(PathGeometry(line(count: 2001, spacing: 5)))
        #expect(abs(geometry.length - 10_000) < 5)

        let midpoint = geometry.point(at: 5000)
        #expect(abs(start.distance(to: midpoint) - 5000) < 5)
    }

    @Test("Invalid coordinates are dropped at construction")
    func filtersInvalid() throws {
        let points = [
            start,
            Coordinate(latitude: 999, longitude: 999),
            start.destination(bearingDegrees: 90, meters: 100),
        ]
        let geometry = try #require(PathGeometry(points))
        #expect(geometry.count == 2)
    }
}
