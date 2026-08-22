import SwiftUI
import UniformTypeIdentifiers
import AnoleCore
import AnoleServices

struct ContentView: View {
    @EnvironmentObject private var model: TripModel
    @State private var panel: Panel? = .device

    /// The panels the sidebar can show, one at a time.
    ///
    /// Everything used to sit on a single scrolling page, which meant hunting
    /// for the one control you wanted. Splitting it into pages keeps each one
    /// short enough to read at a glance.
    enum Panel: String, CaseIterable, Identifiable {
        case device, location, route, gpx

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .device: return "iphone"
            case .location: return "mappin.and.ellipse"
            case .route: return "arrow.triangle.turn.up.right.diamond"
            case .gpx: return "point.topleft.down.to.point.bottomright.curvepath"
            }
        }

        var title: String {
            switch self {
            case .device: return "Device"
            case .location: return "Location"
            case .route: return "Route"
            case .gpx: return "GPX track"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            iconRail
            Divider()

            if let panel {
                panelContent(panel)
                    .frame(width: 300)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            MapPane()
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            model.observeBackend()
            await model.refreshDevices()
        }
        .fileImporter(
            isPresented: $model.presentGPXImporter,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]
        ) { result in
            if case .success(let url) = result { model.loadGPX(from: url) }
        }
        .fileExporter(
            isPresented: $model.presentGPXExporter,
            document: GPXFile(contents: GPXDocument.write(model.recordedTrack, name: "Anole")),
            contentType: UTType(filenameExtension: "gpx") ?? .xml,
            defaultFilename: "trip"
        ) { result in
            if case .failure(let error) = result { model.lastError = error.localizedDescription }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            ),
            actions: { Button("OK") { model.lastError = nil } },
            message: { Text(model.lastError ?? "") }
        )
    }

    /// The always-visible strip of icons. Clicking the open panel closes it.
    private var iconRail: some View {
        VStack(spacing: 4) {
            ForEach(Panel.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        panel = (panel == item) ? nil : item
                    }
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(panel == item ? Color.accentColor.opacity(0.18) : .clear)
                        )
                        .foregroundStyle(panel == item ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(item.title)

                // The track sits apart, below the route it belongs with.
                if item == .route { Spacer().frame(height: 10) }
            }

            Spacer()

            statusDot
        }
        .padding(.vertical, 12)
        .frame(width: 48)
        .background(.bar)
    }

    /// Link state, readable without opening anything.
    private var statusDot: some View {
        Circle()
            .fill(model.isConnected ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .padding(.bottom, 6)
            .help(model.health.label)
    }

    @ViewBuilder
    private func panelContent(_ panel: Panel) -> some View {
        Form {
            switch panel {
            case .device:   deviceSection
            case .location: locationSection
            case .route:    routeSection
            case .gpx:      gpxSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var deviceSection: some View {
                Section("Device") {
                    HStack {
                        Picker("Device", selection: $model.selectedDevice) {
                            Text("None").tag(DeviceInfo?.none)
                            ForEach(model.devices) { device in
                                Text(device.displayName).tag(DeviceInfo?.some(device))
                            }
                        }
                        Button {
                            Task { await model.refreshDevices() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Look for connected devices again")
                    }

                    if model.status.isReady {
                        Button("Disconnect", role: .destructive) {
                            Task { await model.disconnect() }
                        }
                    } else {
                        Button("Connect device") { Task { await model.prepare() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedDevice == nil || model.status.isBusy)
                    }

                    statusRow
                    healthRow

                    Text(connectionExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.preflightIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
    }

    @ViewBuilder
    private var locationSection: some View {
                Section("Location") {
                    if let coordinate = model.currentCoordinate {
                        LabeledContent("Latitude", value: String(format: "%.6f", coordinate.latitude))
                        LabeledContent("Longitude", value: String(format: "%.6f", coordinate.longitude))
                    } else {
                        Text("Click the map").foregroundStyle(.secondary)
                    }

                    Button("Clear on device") { Task { await model.clearLocation() } }
                        .disabled(model.pushedCoordinate == nil)

                    Button("Clear everything", role: .destructive) {
                        Task { await model.resetEverything() }
                    }
                    .disabled(!model.hasSomethingToReset)
                    .help("Gives the iPhone its real location back and empties the map")
                }
    }

    @ViewBuilder
    private var routeSection: some View {
                Section {
                    startRow

                    if let destination = model.destination {
                        LabeledContent("Destination") {
                            Text(String(format: "%.4f, %.4f", destination.latitude, destination.longitude))
                                .font(.callout.monospacedDigit())
                        }

                        Picker("Mode", selection: $model.transportMode) {
                            ForEach(TransportMode.allCases) { mode in
                                Label(mode.label, systemImage: mode.symbolName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: model.transportMode) { _, _ in
                            Task { await model.calculateRoute() }
                        }

                        HStack {
                            Button("Recalculate") { Task { await model.calculateRoute() } }
                                .disabled(model.tripState == .calculating)
                            Button("Clear") { model.clearRoute() }
                        }
                    } else {
                        Text("Click a point on the map, or search for an address, "
                             + "then choose \"Go there\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if model.tripState == .calculating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Calculating the route...").font(.callout)
                        }
                    }

                    if model.routeCandidates.count > 1 {
                        Picker("Route", selection: Binding(
                            get: { model.selectedRoute?.id ?? "" },
                            set: { id in
                                if let plan = model.routeCandidates.first(where: { $0.id == id }) {
                                    model.select(plan)
                                }
                            }
                        )) {
                            ForEach(model.routeCandidates) { plan in
                                Text("\(plan.name) - \(plan.distanceLabel), \(plan.durationLabel)")
                                    .tag(plan.id)
                            }
                        }
                    }

                    if let route = model.selectedRoute {
                        LabeledContent("Distance", value: route.distanceLabel)
                        LabeledContent("Duration", value: route.targetDurationLabel)
                        if let schedule = model.schedule {
                            LabeledContent(
                                "Top speed",
                                value: String(format: "%.0f km/h", cruiseSpeed(schedule) * 3.6)
                            )
                        }
                        if route.hasTolls || route.hasHighways {
                            Text([route.hasTolls ? "tolls" : nil, route.hasHighways ? "highway" : nil]
                                .compactMap { $0 }.joined(separator: " - "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.selectedRoute != nil || model.gpxTrack != nil {
                        speedControls
                    }

                    if model.schedule != nil {
                        tripControls
                    }
                } header: {
                    Text("Route")
                }
    }

    @ViewBuilder
    private var gpxSection: some View {
                Section("GPX track") {
                    if let track = model.gpxTrack {
                        LabeledContent("File", value: track.name)
                        LabeledContent("Points", value: "\(track.points.count)")
                        if let geometry = track.geometry {
                            LabeledContent("Length", value: geometry.length < 1000
                                ? "\(Int(geometry.length)) m"
                                : String(format: "%.1f km", geometry.length / 1000))
                        }
                        if track.recordedDuration != nil, model.speedSettings.averageSpeed == nil {
                            Text("The track's original pace is preserved.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Remove the track") { model.clearGPX() }
                    } else {
                        Button("Open a GPX file...") { model.presentGPXImporter = true }
                        Text("The track is followed like a route, with the same "
                             + "speed settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    recordingRow
                }
    }


    /// Where the trip starts from. The real location by default, without asking.
    @ViewBuilder
    private var startRow: some View {
        if let custom = model.customStart {
            LabeledContent("Start") {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill").foregroundStyle(.indigo)
                    Text(String(format: "%.4f, %.4f", custom.latitude, custom.longitude))
                        .font(.callout.monospacedDigit())
                    Button {
                        model.resetStartToRealPosition()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Start from my real location again")
                }
            }
        } else {
            LabeledContent("Start") {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                    switch model.realLocation.state {
                    case .ready(let fix):
                        Text("My location (±\(Int(fix.accuracy)) m)")
                    case .locating:
                        Text("Locating...").foregroundStyle(.secondary)
                    case .denied:
                        Text("Location denied").foregroundStyle(.red)
                    default:
                        Text("My real location").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Speed settings. By default we follow the routing service duration, which
    /// stays the most believable; these controls are there to depart from it
    /// deliberately.
    @ViewBuilder
    private var speedControls: some View {
        let averageBinding = Binding<Double>(
            get: { (model.speedSettings.averageSpeed ?? 0).metersPerSecondToKmh },
            set: { value in
                model.speedSettings.averageSpeed = value <= 0 ? nil : value.kmhToMetersPerSecond
            }
        )
        let minimumBinding = Binding<Double>(
            get: { model.speedSettings.minimumSpeed.metersPerSecondToKmh },
            set: { model.speedSettings.minimumSpeed = max($0, 0).kmhToMetersPerSecond }
        )
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Force a speed", isOn: Binding(
                get: { model.speedSettings.averageSpeed != nil },
                set: { on in
                    model.speedSettings = on
                        // Start from the value currently computed, to adjust
                        // from realism rather than from zero.
                        ? SpeedSettings(
                            averageSpeed: model.schedule?.averageSpeed
                                ?? model.transportMode.defaultSpeed,
                            minimumSpeed: model.speedSettings.minimumSpeed
                          )
                        : SpeedSettings(averageSpeed: nil, minimumSpeed: 0)
                }
            ))

            if model.speedSettings.averageSpeed != nil {
                LabeledContent("Average") {
                    speedField(averageBinding, placeholder: "50")
                }
                LabeledContent("Minimum") {
                    speedField(minimumBinding, placeholder: "none")
                }

                Text("The minimum only applies at steady state: the start, "
                     + "the destination and the turns stay physical.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let schedule = model.schedule {
                    Text(String(format: "Resulting duration: %@", format(schedule.duration)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let schedule = model.schedule {
                Text(String(format: "Computed average: %.0f km/h", schedule.averageSpeed * 3.6))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Recording of what is actually sent to the iPhone.
    @ViewBuilder
    private var recordingRow: some View {
        Toggle("Record the trip", isOn: Binding(
            get: { model.isRecording },
            set: { _ in model.toggleRecording() }
        ))
        .disabled(!model.isConnected)
        .help(model.isConnected
              ? "Records the locations sent to the iPhone"
              : "Connect the iPhone first")

        if !model.recordedTrack.isEmpty {
            LabeledContent("Recorded points", value: "\(model.recordedTrack.count)")
            HStack {
                Button("Export as GPX...") { model.presentGPXExporter = true }
                Button("Clear") { model.clearRecording() }
            }
        }
    }

    /// Speed field in km/h. No cap: the value entered is what counts.
    private func speedField(_ value: Binding<Double>, placeholder: String) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text("km/h").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tripControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: model.tripProgress)

            HStack {
                switch model.tripState {
                case .playing:
                    Button("Pause") { model.pauseTrip() }
                case .arrived:
                    Text("Arrived").foregroundStyle(.green)
                default:
                    Button("Start") { model.playTrip() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isConnected)
                        .help(model.isConnected
                              ? "Start the trip"
                              : "Connect the iPhone first")
                }
                Button("Stop") { model.stopTrip() }
                    .disabled(model.tripState == .ready || model.tripState == .idle)
            }

            if model.tripState == .playing || model.tripState == .paused {
                HStack {
                    Text(String(format: "%.0f km/h", model.currentSpeed * 3.6))
                    Spacer()
                    Text("\(format(model.remainingTime)) left")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if model.tripState == .arrived {
                Text("The location is held in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// Highest speed of the trip, to give an order of magnitude.
    private func cruiseSpeed(_ schedule: TripSchedule) -> Double {
        stride(from: 0.0, through: schedule.duration, by: max(schedule.duration / 60, 1))
            .map { schedule.sample(at: $0).speed }
            .max() ?? 0
    }

    /// What the button does, in plain words: without this sentence, "Connect"
    /// does not say that it opens a tunnel and mounts an image on the iPhone.
    private var connectionExplanation: String {
        switch model.status {
        case .ready:
            return "The iPhone follows the locations you drop on the map."
        case .preparing:
            return "Opening the tunnel to the iPhone. Keep it unlocked and plugged in."
        case .failed:
            return "Check that the iPhone is plugged in, unlocked, and that developer mode is on."
        case .idle:
            return "Connect mounts the developer disk image on the iPhone and opens the tunnel. "
                 + "Until that is done, locations stay in this window."
        }
    }

    /// Health of the link, distinct from the progress of the preparation:
    /// a session can be "ready" and then drop without warning.
    @ViewBuilder
    private var healthRow: some View {
        switch model.health {
        case .idle:
            EmptyView()
        case .preparing:
            EmptyView()
        case .live(let rtt):
            Label(
                rtt.map { String(format: "Link active - %.0f ms", $0) } ?? "Link active",
                systemImage: "antenna.radiowaves.left.and.right"
            )
            .foregroundStyle(.green)
            .font(.caption)
        case .degraded(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .lost(let reason):
            Label(reason, systemImage: "bolt.horizontal.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.status {
        case .idle:
            Label("Waiting", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .preparing(let step):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(step).font(.callout)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}

/// Minimal wrapper for the file export.
struct GPXFile: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "gpx") ?? .xml] }

    var contents: String

    init(contents: String) { self.contents = contents }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        contents = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(contents.utf8))
    }
}
