import Foundation
import MapKit
import AnoleCore

/// Route calculation through MapKit.
public enum MapKitRouteProvider {

    public enum RouteError: Error, LocalizedError {
        case noRoute
        case timedOut
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noRoute:
                return "No route between these two points."
            case .timedOut:
                return "The route calculation did not answer."
            case .failed(let detail):
                return detail
            }
        }
    }

    /// Computes one or more routes between two points.
    public static func routes(
        from start: Coordinate,
        to end: Coordinate,
        mode: TransportMode,
        alternates: Bool = true
    ) async throws -> [RoutePlan] {
        let request = MKDirections.Request()
        request.source = mapItem(for: start)
        request.destination = mapItem(for: end)
        request.transportType = transportType(for: mode)
        request.requestsAlternateRoutes = alternates
        // Filling in the departure time brings traffic into the announced
        // duration, which makes the calibration more faithful.
        request.departureDate = Date()

        let directions = MKDirections(request: request)

        // A route calculation can stay silent indefinitely: no result, no
        // error, no callback. Without this safeguard the interface would hang.
        let response = try await withThrowingTaskGroup(of: MKDirections.Response?.self) { group in
            group.addTask { try await directions.calculate() }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                directions.cancel()
                return nil
            }
            defer { group.cancelAll() }

            guard let first = try await group.next() else { throw RouteError.timedOut }
            guard let response = first else { throw RouteError.timedOut }
            return response
        }

        let plans = response.routes.enumerated().compactMap { index, route in
            plan(from: route, mode: mode, index: index)
        }
        guard !plans.isEmpty else { throw RouteError.noRoute }
        return plans
    }

    // MARK: - Conversion

    private static func plan(from route: MKRoute, mode: TransportMode, index: Int) -> RoutePlan? {
        let coordinates = self.coordinates(of: route.polyline)
        guard coordinates.count >= 2 else { return nil }

        // Steps carry a distance, never an individual duration: we accumulate
        // the distances to know where each step ends.
        var cumulative = 0.0
        var stepEnds: [Double] = []
        for step in route.steps {
            cumulative += step.distance
            stepEnds.append(cumulative)
        }
        // The last boundary is the destination: it is not a stop along the way.
        if !stepEnds.isEmpty { stepEnds.removeLast() }

        return RoutePlan(
            id: "route-\(index)",
            name: route.name.isEmpty ? "Route \(index + 1)" : route.name,
            coordinates: coordinates,
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            stepEndArcLengths: stepEnds,
            mode: mode,
            routingBasis: routingMode(for: mode),
            hasTolls: route.hasTolls,
            hasHighways: route.hasHighways
        )
    }

    private static func coordinates(of polyline: MKPolyline) -> [Coordinate] {
        var points = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: polyline.pointCount
        )
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        return points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private static func mapItem(for coordinate: Coordinate) -> MKMapItem {
        let point = CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // The macOS 26 initialiser has to be hidden from older compilers as well
        // as from older systems. `#available` guards what runs, not what
        // builds: a toolchain whose SDK predates the API cannot compile the
        // branch at all, and the whole package fails on a stable Xcode. CI
        // caught that on the first run.
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            return MKMapItem(
                location: CLLocation(latitude: point.latitude, longitude: point.longitude),
                address: nil
            )
        }
        #endif
        return MKMapItem(placemark: MKPlacemark(coordinate: point))
    }

    /// Mode actually asked of the service. MapKit does not know cycling: we
    /// take a walking route, which uses comparable ways.
    private static func routingMode(for mode: TransportMode) -> TransportMode {
        mode == .cycling ? .walking : mode
    }

    private static func transportType(for mode: TransportMode) -> MKDirectionsTransportType {
        switch routingMode(for: mode) {
        case .driving: return .automobile
        case .walking, .cycling: return .walking
        }
    }
}
