import SwiftUI
import MapKit
import AnoleCore
import AnoleServices

/// Main screen of the iPhone app.
///
/// Everything used often stays visible on the map: status, recentring and the
/// actions for the selected point. The sliding panel only holds the settings,
/// which are not consulted on every operation.
struct iOSContentView: View {
    @EnvironmentObject private var model: TripModel
    @StateObject private var search = PlaceSearchModel()
    @FocusState private var searchFocused: Bool

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.4193),
            span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
        )
    )
    @State private var showsSettings = false
    @State private var hasCentredOnUser = false

    var body: some View {
        map
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .trailing) { recentreButtons }
            .overlay(alignment: .bottom) { bottomPanel }
            .ignoresSafeArea(edges: .bottom)
            .task {
                model.observeBackend()
                await model.refreshDevices()
                // The app opens on wherever the user happens to be.
                if let fix = await model.realLocation.currentFix() {
                    centre(fix.coordinate, span: max(fix.accuracy / 30_000, 0.006))
                    hasCentredOnUser = true
                }
            }
            .sheet(isPresented: $showsSettings) { settingsSheet }
            .alert("Error", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            ), actions: { Button("OK") { model.lastError = nil } },
               message: { Text(model.lastError ?? "") })
    }

    // MARK: - Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let route = model.selectedRoute {
                    MapPolyline(coordinates: route.coordinates.map(\.clLocation))
                        .stroke(.blue, lineWidth: 5)
                }
                if let fix = model.realLocation.fix {
                    MapCircle(center: fix.coordinate.clLocation, radius: fix.accuracy)
                        .foregroundStyle(.blue.opacity(0.12))
                        .stroke(.blue.opacity(0.35), lineWidth: 1)
                    Annotation("Real location", coordinate: fix.coordinate.clLocation) {
                        Circle().fill(.blue).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .shadow(radius: 2)
                    }
                    .annotationTitles(.hidden)
                }
                if let pending = model.pendingPoint {
                    Annotation("Selected", coordinate: pending.clLocation) {
                        pin(symbol: "mappin", tint: .purple)
                    }
                    .annotationTitles(.hidden)
                }
                if let destination = model.destination {
                    Annotation("Destination", coordinate: destination.clLocation) {
                        pin(symbol: "flag.checkered", tint: .red)
                    }
                    .annotationTitles(.hidden)
                }
                if let point = model.currentCoordinate {
                    Annotation("Simulated", coordinate: point.clLocation) {
                        pin(symbol: "iphone", tint: model.isConnected ? .green : .orange)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { search.biasRegion = $0.region }
            .onTapGesture { screenPoint in
                searchFocused = false
                guard let point = proxy.convert(screenPoint, from: .local) else { return }
                model.proposePoint(Coordinate(latitude: point.latitude, longitude: point.longitude))
            }
        }
    }

    private func pin(symbol: String, tint: Color) -> some View {
        VStack(spacing: -3) {
            ZStack {
                Circle().fill(tint).frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            Triangle().fill(tint).frame(width: 10, height: 8)
        }
        .shadow(radius: 2, y: 1)
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: 8) {
            searchField
            HStack {
                Spacer()
                statusBadge
            }
        }
        .padding(.horizontal, 12)
    }

    private var searchField: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Address, place or coordinates", text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        Task {
                            if let point = await search.searchDirectly() { choose(point) }
                        }
                    }
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)

            if searchFocused, !search.suggestions.isEmpty {
                Divider()
                ForEach(search.suggestions.prefix(5)) { suggestion in
                    Button {
                        Task {
                            if let point = await search.resolve(suggestion) { choose(point) }
                        }
                    } label: {
                        HStack {
                            Image(systemName: suggestion.isDirect ? "scope" : "mappin.circle")
                                .foregroundStyle(suggestion.isDirect ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title).lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    /// Link status, always visible, and the connect button.
    private var statusBadge: some View {
        Button {
            Task {
                if model.isConnected { await model.disconnect() } else { await model.prepare() }
            }
        } label: {
            HStack(spacing: 6) {
                if model.status.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(model.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                }
                Text(badgeLabel).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(model.status.isBusy)
    }

    private var badgeLabel: String {
        if model.status.isBusy { return "Connecting..." }
        return model.isConnected ? "Connected" : "Connect"
    }

    // MARK: - Recentring

    private var recentreButtons: some View {
        VStack(spacing: 0) {
            Button {
                Task {
                    if let fix = await model.realLocation.currentFix() {
                        centre(fix.coordinate, span: max(fix.accuracy / 30_000, 0.006))
                    }
                }
            } label: {
                Image(systemName: model.realLocation.fix == nil ? "location" : "location.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
            }

            Divider().frame(width: 28)

            Button {
                if let point = model.currentCoordinate { centre(point, span: 0.01) }
            } label: {
                Image(systemName: "scope")
                    .foregroundStyle(model.currentCoordinate == nil ? Color.secondary : Color.orange)
                    .frame(width: 40, height: 40)
            }
            .disabled(model.currentCoordinate == nil)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .padding(.trailing, 12)
    }

    // MARK: - Bottom panel

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if let pending = model.pendingPoint {
                pendingActions(pending)
            } else if model.tripState == .calculating {
                routePreparation
            } else if model.schedule != nil {
                tripControls
            }

            HStack {
                Button("Clear everything", systemImage: "trash") {
                    Task { await model.resetEverything() }
                }
                .font(.caption)
                .foregroundStyle(.red)
                .disabled(!model.hasSomethingToReset)

                Spacer()
                Button("Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                    .font(.caption)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.bottom, 28)
    }

    private func pendingActions(_ pending: Coordinate) -> some View {
        VStack(spacing: 8) {
            Text(String(format: "%.5f, %.5f", pending.latitude, pending.longitude))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    model.teleportToPendingPoint()
                } label: {
                    Label("Here", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected)

                Menu {
                    ForEach(TransportMode.allCases) { mode in
                        Button {
                            Task { await model.routeToPendingPoint(mode: mode) }
                        } label: {
                            Label(mode.label, systemImage: mode.symbolName)
                        }
                    }
                } label: {
                    Label("Travel there", systemImage: model.transportMode.symbolName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    model.cancelPendingPoint()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Shown while the route is being prepared.
    ///
    /// Without it the panel stays empty for several seconds, which reads as
    /// nothing having happened - the reason this exists at all.
    @ViewBuilder
    private var routePreparation: some View {
        if let phase = model.routePhase {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(phase.label).font(.caption)
                    Spacer()
                    Text("\(Int(model.routeProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: model.routeProgress)
                    .animation(.easeOut(duration: 0.2), value: model.routeProgress)
            }
        }
    }

    @ViewBuilder
    private var tripControls: some View {
        if let route = model.selectedRoute {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(route.distanceLabel) · \(model.simulatedDurationLabel ?? route.targetDurationLabel)")
                        if let limits = model.speedLimitSummary {
                            Text(limits).font(.caption2)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.tripState == .playing {
                        HStack(spacing: 5) {
                            Text(String(format: "%.0f km/h", model.currentSpeed * 3.6))
                            if let limit = model.currentSpeedLimit {
                                Text(String(format: "/ %.0f", limit * 3.6))
                                    .foregroundStyle(.secondary)
                            }
                        }
                            .font(.caption.monospacedDigit())
                    }
                }
                ProgressView(value: model.tripProgress)

                HStack(spacing: 8) {
                    switch model.tripState {
                    case .playing:
                        Button("Pause", systemImage: "pause.fill") { model.pauseTrip() }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    case .arrived:
                        Label("Arrived", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).frame(maxWidth: .infinity)
                    default:
                        Button("Start", systemImage: "play.fill") { model.playTrip() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.isConnected)
                            .frame(maxWidth: .infinity)
                    }
                    Button("Clear", systemImage: "xmark") { model.clearRoute() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Settings

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Status", value: model.health.label)
                    Picker("Mode", selection: $model.transportMode) {
                        ForEach(TransportMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                }
                Section {
                    Toggle("Read limits from OpenStreetMap", isOn: $model.fetchSpeedLimits)
                } header: {
                    Text("Speed limits")
                } footer: {
                    Text("Sends the area around the route — your real location included — "
                         + "to a public Overpass server. Off, the trip runs on the pace of "
                         + "the mode.")
                }
                Section("Real location") {
                    if let fix = model.realLocation.fix {
                        LabeledContent("Accuracy", value: "±\(Int(fix.accuracy)) m")
                    } else {
                        Button("Locate") {
                            Task { _ = await model.realLocation.currentFix() }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { showsSettings = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Utilities

    /// A place picked from the search behaves like a tapped point.
    private func choose(_ point: Coordinate) {
        searchFocused = false      // without this the keyboard stays in front of the map
        search.query = ""
        model.proposePoint(point)
        centre(point, span: 0.02)
    }

    private func centre(_ coordinate: Coordinate, span: Double) {
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(
                center: coordinate.clLocation,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            ))
        }
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
