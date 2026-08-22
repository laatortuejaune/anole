import SwiftUI
import MapKit
import AnoleCore
import AnoleServices

struct MapPane: View {
    @EnvironmentObject private var model: TripModel
    @StateObject private var search = PlaceSearchModel()


    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            // the Bay Area by default.
            center: CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.4193),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    )

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                routeOverlay
                realLocationOverlay
                simulatedLocationOverlay
            }
            .mapStyle(.standard(elevation: .flat))
            // The visible region is used to favor nearby search results.
            .onMapCameraChange(frequency: .onEnd) { context in
                search.biasRegion = context.region
            }
            .onTapGesture { screenPoint in
                guard let point = proxy.convert(screenPoint, from: .local) else { return }
                model.proposePoint(Coordinate(latitude: point.latitude, longitude: point.longitude))
            }
        }
        .overlay(alignment: .topLeading) { searchBar }
        .overlay(alignment: .bottomTrailing) { recenterButtons }
        .overlay(alignment: .bottomLeading) { statusHint }
        .overlay(alignment: .bottom) { pendingChoice }
        .onChange(of: model.selectedRoute?.id) { _, _ in
            // A freshly computed route should be visible without panning
            // around to find it.
            frameRoute()
        }
        .onChange(of: model.realLocation.fix) { _, fix in
            // First fix received after a request: frame the map on it.
            guard let fix else { return }
            focus(on: fix.coordinate, span: max(fix.accuracy / 30_000, 0.004))
        }
    }

    // MARK: - Map content

    @MapContentBuilder
    private var realLocationOverlay: some MapContent {
        if let fix = model.realLocation.fix {
            // The accuracy circle matters as much as the point: on a Mac, the
            // location comes from Wi-Fi and can be off by 50 to 100 m.
            MapCircle(center: fix.coordinate.clLocation, radius: fix.accuracy)
                .foregroundStyle(.blue.opacity(0.12))
                .stroke(.blue.opacity(0.35), lineWidth: 1)

            Annotation("Real location", coordinate: fix.coordinate.clLocation) {
                RealPositionMarker()
            }
            .annotationTitles(.hidden)
        }
    }

    @MapContentBuilder
    private var simulatedLocationOverlay: some MapContent {
        if let coordinate = model.currentCoordinate {
            Annotation("Simulated location", coordinate: coordinate.clLocation) {
                // The color follows the state of the LINK, not the equality of
                // the coordinates: during a trip the location changes five times
                // per second and the acknowledgement arrives just after, which
                // made the marker blink permanently.
                SimulatedPositionMarker(live: model.isConnected)
            }
            .annotationTitles(.hidden)
        }
    }

    @MapContentBuilder
    private var routeOverlay: some MapContent {
        if let track = model.gpxTrack {
            MapPolyline(coordinates: track.points.map(\.coordinate.clLocation))
                .stroke(.purple, lineWidth: 4)
        }
        if let route = model.selectedRoute {
            MapPolyline(coordinates: route.coordinates.map(\.clLocation))
                .stroke(.blue, lineWidth: 5)
        }
        if model.recordedTrack.count > 1 {
            MapPolyline(coordinates: model.recordedTrack.map(\.coordinate.clLocation))
                .stroke(.orange, lineWidth: 3)
        }
        if let pending = model.pendingPoint {
            Annotation("Chosen point", coordinate: pending.clLocation) {
                PinMarker(symbol: "mappin", tint: .purple)
            }
            .annotationTitles(.hidden)
        }
        if let start = model.customStart {
            Annotation("Start", coordinate: start.clLocation) {
                PinMarker(symbol: "flag.fill", tint: .indigo)
            }
            .annotationTitles(.hidden)
        }
        if let destination = model.destination {
            Annotation("Destination", coordinate: destination.clLocation) {
                PinMarker(symbol: "flag.checkered", tint: .red)
            }
            .annotationTitles(.hidden)
        }
    }

    // MARK: - Overlays

    private var searchBar: some View {
        SearchBar(search: search) { coordinate in
            // An address that is found behaves like a click on the map: we
            // propose it, the user chooses to drop there or to travel there.
            model.proposePoint(coordinate)
            focus(on: coordinate, span: 0.01)
        }
    }

    private var recenterButtons: some View {
        VStack(spacing: 0) {
            Button {
                if let fix = model.realLocation.fix {
                    focus(on: fix.coordinate, span: max(fix.accuracy / 30_000, 0.004))
                } else {
                    model.realLocation.request()
                }
            } label: {
                Label("My real location", systemImage: realIcon)
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 28)
            }
            .help(realHelp)
            .disabled(model.realLocation.state == .locating)

            Divider().frame(width: 22)

            Button {
                guard let coordinate = model.currentCoordinate else { return }
                focus(on: coordinate, span: 0.01)
            } label: {
                Label("Simulated location", systemImage: "scope")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(model.currentCoordinate == nil ? Color.secondary : Color.orange)
                    .frame(width: 30, height: 28)
            }
            .help("Recenter on the simulated location")
            .disabled(model.currentCoordinate == nil)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .padding(12)
    }

    private var realIcon: String {
        switch model.realLocation.state {
        case .ready: return "location.fill"
        case .locating: return "location.circle"
        case .denied, .failed: return "location.slash"
        default: return "location"
        }
    }

    private var realHelp: String {
        switch model.realLocation.state {
        case .ready(let fix): return "Your real location, to ±\(Int(fix.accuracy)) m"
        case .locating: return "Locating..."
        case .denied: return "Permission denied. Open Settings > Privacy."
        case .failed(let message): return message
        default: return "Show your real location"
        }
    }

    /// Choice offered after a click: drop right there, or travel there by road.
    @ViewBuilder
    private var pendingChoice: some View {
        if let pending = model.pendingPoint {
            VStack(spacing: 8) {
                Text(String(format: "%.5f, %.5f", pending.latitude, pending.longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        model.teleportToPendingPoint()
                    } label: {
                        Label("Put me here", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected)

                    // A click starts with the last mode used; the arrow allows
                    // picking another one on the way.
                    Menu {
                        ForEach(TransportMode.allCases) { mode in
                            Button {
                                Task { await model.routeToPendingPoint(mode: mode) }
                            } label: {
                                Label(mode.label, systemImage: mode.symbolName)
                            }
                        }
                    } label: {
                        Label("Go there", systemImage: model.transportMode.symbolName)
                    } primaryAction: {
                        Task { await model.routeToPendingPoint(mode: model.transportMode) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    // The special case stays within reach, without cluttering.
                    Menu {
                        Button("Start from here rather than from my location") {
                            model.usePendingPointAsStart()
                        }
                        if model.customStart != nil {
                            Button("Start from my real location again") {
                                model.resetStartToRealPosition()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Other options")

                    Button {
                        model.cancelPendingPoint()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Cancel")
                }

                if !model.isConnected {
                    Label("Connect the iPhone to act on its location",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(16)
        }
    }

    @ViewBuilder
    private var statusHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let message) = model.realLocation.state {
                hintLabel(message, icon: "exclamationmark.triangle.fill", tint: .orange)
            } else if case .denied = model.realLocation.state {
                Button {
                    DeviceLocationProvider.openSettings()
                } label: {
                    hintLabel(
                        "Location denied. Open Settings",
                        icon: "location.slash",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
            }

            if model.currentCoordinate == nil, model.pendingPoint == nil {
                hintLabel("Click the map to drop the location", icon: "hand.tap", tint: .secondary)
            }
        }
        .padding(12)
    }

    private func hintLabel(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    /// Frames the whole route, with a little air around it.
    private func frameRoute() {
        guard let route = model.selectedRoute, route.coordinates.count > 1 else { return }
        let latitudes = route.coordinates.map(\.latitude)
        let longitudes = route.coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.01)
            )
        )
        withAnimation(.easeInOut(duration: 0.5)) { camera = .region(region) }
    }

    private func focus(on coordinate: Coordinate, span: Double) {
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(
                center: coordinate.clLocation,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            ))
        }
    }
}

// MARK: - Markers

/// Real location: the blue dot familiar from map applications.
private struct RealPositionMarker: View {
    var body: some View {
        Circle()
            .fill(.blue)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 2)
            .help("Real location of the Mac")
    }
}

/// Generic marker: the same pointed bubble as the simulated location, so that
/// every point dropped on the map forms a coherent family.
private struct PinMarker: View {
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: -3) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            Triangle()
                .fill(tint)
                .frame(width: 9, height: 7)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// Simulated location: a pin, deliberately different from the blue dot so the
/// two are never confused at a glance.
private struct SimulatedPositionMarker: View {
    let live: Bool

    var body: some View {
        VStack(spacing: -3) {
            ZStack {
                Circle()
                    .fill(live ? Color.green : Color.orange)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: "iphone")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            // Tip of the pin: it designates the exact coordinate.
            Triangle()
                .fill(live ? Color.green : Color.orange)
                .frame(width: 9, height: 7)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        // Green: the location is applied on the iPhone. Orange: it only exists
        // in this window.
        .help(live ? "Location applied on the iPhone" : "iPhone not connected")
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

extension Coordinate {
    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
