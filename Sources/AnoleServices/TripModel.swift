import Foundation
import SwiftUI
import Combine
import AnoleCore

/// All the simulation logic, shared by both applications.
///
/// The backend is injected: the macOS application passes it the one that drives
/// the Python daemon, the iPhone application the one that talks directly to the
/// device services. Nothing else sets them apart.
@MainActor
public final class TripModel: ObservableObject {

    public enum Status: Equatable {
        case idle
        case preparing(String)
        case ready
        case failed(String)

        public var isReady: Bool { self == .ready }

        /// An operation is under way: the button must stay disabled.
        public var isBusy: Bool {
            if case .preparing = self { return true }
            return false
        }
    }

    // MARK: Device and backend

    @Published public private(set) var devices: [DeviceInfo] = []
    @Published public var selectedDevice: DeviceInfo?
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var preflightIssues: [String] = []

    // MARK: Location

    /// Location shown on the map. Stays nil until a point has been dropped.
    @Published public var currentCoordinate: Coordinate?
    /// Location actually pushed to the device.
    @Published public private(set) var pushedCoordinate: Coordinate?

    /// Mode used for the route calculation and the speed profile.
    @Published public var transportMode: TransportMode = .driving

    /// Speed settings of the trip. Recompute the schedule as soon as they change.
    @Published public var speedSettings: SpeedSettings = .automatic {
        didSet {
            guard speedSettings != oldValue else { return }
            if let route = selectedRoute {
                select(route)
            } else if let track = gpxTrack, let geometry = track.geometry {
                buildScheduleForTrack(track, geometry: geometry)
            }
        }
    }

    @Published public var lastError: String?
    @Published public private(set) var health: BackendHealth = .idle

    // MARK: Route

    public enum TripState: Equatable {
        case idle
        case calculating
        case ready
        case playing
        case paused
        case arrived
    }

    @Published public var destination: Coordinate?
    /// Point dropped on the map, awaiting a decision: teleport to it, or
    /// travel there by road.
    @Published public var pendingPoint: Coordinate?
    /// Start chosen by hand. `nil` means "my real location", which is the
    /// normal behavior: you leave from where you are.
    @Published public var customStart: Coordinate?

    /// Real location of the Mac. It serves as the default start of every route.
    public let realLocation = DeviceLocationProvider()
    /// Relays its changes into ours.
    ///
    /// A nested ObservableObject publishes on its own; nothing observing this
    /// model ever hears it. "My real location" moved the provider to `.ready`
    /// and no view redrew — the map did not recentre, the blue dot stayed
    /// away — until some unrelated publish happened to force a render. The
    /// 5 Hz tick of a running trip hid it most of the time, which is what made
    /// it look intermittent.
    private var realLocationRelay: AnyCancellable?

    // MARK: GPX track

    /// Track loaded from a file. It plays back exactly like a computed route:
    /// same engine, same speed settings, same playback controls.
    @Published public private(set) var gpxTrack: GPXTrack?
    @Published public var presentGPXImporter = false

    /// Recording of the locations actually sent to the iPhone.
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordedTrack: [TrackPoint] = []
    @Published public var presentGPXExporter = false
    @Published public private(set) var routeCandidates: [RoutePlan] = []
    @Published public var selectedRoute: RoutePlan?
    @Published public private(set) var tripState: TripState = .idle
    /// Step the route preparation has reached, nil when nothing is being prepared.
    @Published public private(set) var routePhase: RoutePhase?
    /// Overall progress of that preparation, 0 to 1.
    @Published public private(set) var routeProgress: Double = 0
    private var routeProgressTask: Task<Void, Never>?
    /// Progress along the trip, from 0 to 1.
    @Published public private(set) var tripProgress: Double = 0
    @Published public private(set) var currentSpeed: Double = 0
    /// Whether to fetch road speed limits from OpenStreetMap.
    ///
    /// It is a genuine trade-off, so it is offered rather than decided here.
    /// Computing a route posts the boxes covering it to a public Overpass
    /// instance, and since the default start is the real Core Location fix, the
    /// first of those boxes contains where you actually are — sent outside
    /// Apple's ecosystem, to a volunteer-run server, by an app whose point is
    /// keeping that to yourself. Turning it off costs the speed limits and
    /// nothing else: the trip runs on the pace of the mode, as it did before
    /// they existed.
    @Published public var fetchSpeedLimits: Bool = UserDefaults.standard.object(
        forKey: "fetchSpeedLimits"
    ) as? Bool ?? true {
        didSet { UserDefaults.standard.set(fetchSpeedLimits, forKey: "fetchSpeedLimits") }
    }

    /// Why the speed limits could not be fetched, nil when they were.
    @Published public private(set) var speedLimitFailure: String?
    /// Limit of the road under the moving point, nil when unknown.
    @Published public private(set) var currentSpeedLimit: Double?
    @Published public private(set) var remainingTime: TimeInterval = 0
    @Published public private(set) var schedule: TripSchedule?
    /// Last lines from the helper, to diagnose without leaving the app.
    @Published public private(set) var logLines: [String] = []

    private let backend: LocationBackend

    public init(backend: LocationBackend) {
        self.backend = backend
    }
    private var observationTask: Task<Void, Never>?
    private var tripTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    /// Time already covered in the trip, kept across pause and resume.
    private var tripElapsed: TimeInterval = 0

    /// Rate at which the location is re-emitted during a movement.
    /// The developer service only pins a fixed point: to give the illusion of
    /// continuous movement, it has to be pushed again regularly.
    ///
    /// Measured over USB on a recent iPhone: round trip on the order of 10 ms.
    /// Five locations per second therefore leave a very wide
    /// margin, and make the movement noticeably smoother than at 1 Hz.
    public let tickInterval: TimeInterval = 0.2

    // MARK: - Lifecycle

    /// The interface never queries the backend: it receives its state.
    ///
    /// Called once and only once. `backend.events` is a single AsyncStream
    /// created at init: cancelling an iteration terminates it for good. Since
    /// this runs from the `.task` of the content view, Cmd+N or closing and
    /// reopening the window used to be enough to kill it — after which a lost
    /// tunnel no longer stopped the trip, the health banner froze, and the trip
    /// played on against a dead link.
    public func observeBackend() {
        guard observationTask == nil else { return }
        if realLocationRelay == nil {
            realLocationRelay = realLocation.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        let stream = backend.events
        observationTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .health(let value):
                    self.health = value
                    if case .lost(let reason) = value {
                        self.stopTrip()
                        self.status = .failed(reason)
                    }
                case .log(let line):
                    self.logLines.append(line)
                    if self.logLines.count > 200 { self.logLines.removeFirst() }
                }
            }
        }
    }

    public func refreshDevices() async {
        preflightIssues = await backend.preflight()
        do {
            devices = try await backend.discoverDevices()
            if selectedDevice == nil || !devices.contains(where: { $0.udid == selectedDevice?.udid }) {
                selectedDevice = devices.first
            }
        } catch {
            devices = []
            report(error)
        }
    }

    public func prepare() async {
        guard let device = selectedDevice else {
            status = .failed(BackendError.noDeviceFound.localizedDescription)
            return
        }
        status = .preparing(PreparationStep.checkingTooling.label)
        do {
            try await backend.prepare(device: device) { [weak self] step in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = step {
                        self.status = .ready
                    } else {
                        self.status = .preparing(step.label)
                    }
                }
            }
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
            report(error)
        }
    }

    // MARK: - Location

    /// A click on the map decides nothing: it proposes.
    public func proposePoint(_ coordinate: Coordinate) {
        pendingPoint = coordinate
    }

    /// True when the device is ready to receive locations.
    public var isConnected: Bool { status.isReady }

    private func requireConnection() -> Bool {
        guard status.isReady else {
            lastError = "Connect the iPhone first: \"Connect device\" button."
            return false
        }
        return true
    }

    /// Land on the chosen point immediately.
    public func teleportToPendingPoint() {
        guard requireConnection() else { return }
        guard let point = pendingPoint else { return }
        stopTrip()
        clearRouteKeepingPosition()
        pendingPoint = nil
        moveTo(point)
    }

    /// Compute a route to the chosen point, with the selected mode.
    public func routeToPendingPoint(mode: TransportMode) async {
        guard let point = pendingPoint else { return }
        pendingPoint = nil
        transportMode = mode
        destination = point
        await calculateRoute()

        // Asking to go somewhere means going: no reason to make the user hunt
        // for a start button afterwards. The default speed settings already
        // match what the routing service predicts, so the trip is believable
        // without touching anything.
        if tripState == .ready, isConnected {
            playTrip()
        }
    }

    /// Use this point as the start of the trip, instead of the real location.
    public func usePendingPointAsStart() {
        guard let point = pendingPoint else { return }
        customStart = point
        pendingPoint = nil
    }

    public func resetStartToRealPosition() {
        customStart = nil
        Task { _ = await realLocation.currentFix() }
    }

    public func cancelPendingPoint() {
        pendingPoint = nil
    }

    /// Clears the route without moving the current location.
    private func clearRouteKeepingPosition() {
        routeCandidates = []
        selectedRoute = nil
        schedule = nil
        destination = nil
        tripState = .idle
    }

    /// Effective start point of the route, for display.
    public var effectiveStart: Coordinate? {
        customStart ?? realLocation.fix?.coordinate
    }

    public func moveTo(_ coordinate: Coordinate, push: Bool = true) {
        currentCoordinate = coordinate
        guard push else { return }
        Task { await pushCurrent() }
        // The developer service holds nothing by itself: a coordinate pushed
        // once is forgotten and the device finds its real position again within
        // seconds. The keep-alive existed only after a trip arrived, so a plain
        // teleport drifted away on its own.
        startKeepAlive()
        updateBackgroundHold()
    }

    private func pushCurrent() async {
        guard status.isReady, let coordinate = currentCoordinate else { return }
        do {
            try await backend.setLocation(coordinate)
            pushedCoordinate = coordinate
            recordIfNeeded(coordinate)
        } catch {
            report(error)
        }
    }

    public func clearLocation() async {
        do {
            try await backend.clearLocation(settlingNear: nil)
            pushedCoordinate = nil
        } catch {
            report(error)
        }
    }

    // MARK: - Recording

    public func toggleRecording() {
        isRecording.toggle()
        if isRecording { recordedTrack = [] }
    }

    public func clearRecording() {
        recordedTrack = []
    }

    public func exportRecordedTrack(to url: URL) {
        do {
            let xml = GPXDocument.write(recordedTrack, name: "Anole")
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            report(error)
        }
    }

    /// Records only significant movements.
    ///
    /// Locations go out five times a second: keeping them all would produce
    /// enormous, unreadable files, for a strictly identical track.
    private func recordIfNeeded(_ coordinate: Coordinate) {
        guard isRecording else { return }
        if let last = recordedTrack.last?.coordinate,
           last.distance(to: coordinate) < 3 {
            return
        }
        recordedTrack.append(TrackPoint(coordinate: coordinate, timestamp: Date()))
    }

    // MARK: - GPX track

    public func loadGPX(from url: URL) {
        do {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let track = try GPXDocument.load(from: url)
            guard let geometry = track.geometry else {
                throw GPXDocument.GPXError.noTrackPoints
            }

            stopTrip()
            clearRouteKeepingPosition()
            gpxTrack = track
            buildScheduleForTrack(track, geometry: geometry)
            tripState = .ready
            if let start = schedule?.sample(at: 0).coordinate { currentCoordinate = start }
        } catch {
            report(error)
        }
    }

    public func clearGPX() {
        stopTrip()
        gpxTrack = nil
        schedule = nil
        tripState = .idle
    }

    private func buildScheduleForTrack(_ track: GPXTrack, geometry: PathGeometry) {
        let settings = speedSettings.clamped(to: transportMode)
        // A timestamped track carries its own pace: we honor it, unless a speed
        // has been imposed explicitly.
        let target = settings.targetDuration(forDistance: geometry.length)
            ?? track.recordedDuration

        // The ceiling comes from the manual setting if there is one, otherwise
        // from the pace of the track itself: a car track played back in walking
        // mode must not be brought down to a pedestrian's pace.
        let ceiling = settings.speedCeiling(for: transportMode)
            ?? track.speedCeiling(for: transportMode)

        schedule = TripSchedule.calibrated(
            geometry: geometry,
            mode: transportMode,
            minimumSpeed: settings.minimumSpeed,
            speedCeiling: ceiling,
            targetDuration: target
        )
        tripElapsed = 0
        tripProgress = 0
        remainingTime = schedule?.duration ?? 0
    }

    // MARK: - Route

    /// Computes a route to the destination.
    ///
    /// The start is the real location of the Mac, unless a start has been placed
    /// by hand in advanced mode. That is the expected behavior: you leave from
    /// where you are, without having to say so.
    public func calculateRoute() async {
        guard let end = destination else {
            lastError = "Choose a destination."
            return
        }

        tripState = .calculating
        let start: Coordinate
        if let customStart {
            start = customStart
        } else if let fix = await realLocation.currentFix() {
            start = fix.coordinate
        } else if let fallback = currentCoordinate {
            // Without a real location, at least leave from the simulated one.
            start = fallback
        } else {
            tripState = .idle
            lastError = "Real location unavailable. Allow location access, "
                      + "or place a start from the route menu."
            return
        }

        stopTrip()
        routeCandidates = []
        selectedRoute = nil
        schedule = nil

        do {
            beginPhase(.routing)
            let plans = try await MapKitRouteProvider.routes(
                from: start, to: end, mode: transportMode
            )
            // Only driving reads limits; announcing the step for a walk would
            // name something that never runs.
            let wantsLimits = fetchSpeedLimits && transportMode == .driving
            if wantsLimits { beginPhase(.speedLimits) }
            let enriched = wantsLimits ? await Self.withSpeedLimits(plans) : plans
            speedLimitFailure = wantsLimits
                ? await OverpassSpeedLimits.shared.lastFailure
                : nil

            beginPhase(.profile)
            routeCandidates = enriched
            select(enriched[0])
            tripState = .ready
            endPhases()
        } catch {
            endPhases()
            tripState = .idle
            report(error)
        }
    }

    /// Enters a preparation step and starts creeping the bar through it.
    ///
    /// The progress is an estimate and makes no secret of it: each tick closes a
    /// fixed share of the distance left to the ceiling, so the bar slows as it
    /// approaches and never pretends the step is finished. A step that returns
    /// early simply jumps to the next one.
    private func beginPhase(_ phase: RoutePhase) {
        routePhase = phase
        routeProgress = max(routeProgress, phase.startFraction)
        routeProgressTask?.cancel()
        routeProgressTask = Task { [weak self] in
            let tick = 0.1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard let self, self.routePhase == phase, !Task.isCancelled else { return }
                let remaining = phase.ceilingFraction - self.routeProgress
                guard remaining > 0.0005 else { continue }
                self.routeProgress += remaining * (tick / phase.expectedDuration)
            }
        }
    }

    private func endPhases() {
        routeProgressTask?.cancel()
        routeProgressTask = nil
        routePhase = nil
        routeProgress = 0
    }

    /// Attaches the OpenStreetMap speed limits to freshly computed routes.
    ///
    /// This runs before the route is offered, not after, because asking to go
    /// somewhere starts the trip straight away: enriching in the background
    /// would land after departure, when the schedule is already playing and
    /// must not be rebuilt underneath it.
    ///
    /// A failure changes nothing. The routes come back exactly as they went in
    /// and the trip runs on the pace of the mode, which is what it did before
    /// speed limits existed at all.
    static func withSpeedLimits(_ plans: [RoutePlan]) async -> [RoutePlan] {
        guard plans.first?.mode == .driving else { return plans }

        let segments = await OverpassSpeedLimits.shared.segments(
            alongTracks: plans.map(\.coordinates)
        )
        guard !segments.isEmpty else { return plans }

        return plans.map { plan in
            guard let geometry = plan.geometry else { return plan }
            var enriched = plan
            enriched.speedSamples = SpeedLimitMatcher.samples(
                geometry: geometry, segments: segments, mode: plan.mode
            )
            return enriched
        }
    }

    /// Duration the trip will actually take, which is not always the one the
    /// routing service announces.
    public var simulatedDurationLabel: String? {
        guard let schedule else { return nil }
        let minutes = Int((schedule.duration / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Said out loud when the simulated duration departs from the announced one.
    ///
    /// Apple's estimate assumes the pace real traffic holds, which on some roads
    /// means sitting on the limit or a little over. Anole never crosses it, and
    /// it also stops at junctions and slows into bends. When those two cannot be
    /// reconciled the trip is the slower of the two - and says so, rather than
    /// displaying a duration it will not honour.
    public var durationNote: String? {
        guard let schedule, let route = selectedRoute else { return nil }
        let target = route.targetDuration
        guard target > 0 else { return nil }
        let drift = (schedule.duration - target) / target
        guard abs(drift) > 0.05 else { return nil }
        let minutes = Int((target / 60).rounded())
        return drift > 0
            ? "Apple predicts \(minutes) min; the limits of these roads do not allow it"
            : "Apple predicts \(minutes) min; these roads allow better"
    }

    /// What the route knows about its speed limits, for display.
    ///
    /// Stated plainly rather than hidden: a trip that silently falls back on the
    /// pace of the mode looks exactly like one that failed, and there was no way
    /// to tell them apart.
    public var speedLimitSummary: String? {
        guard let route = selectedRoute, route.mode == .driving else { return nil }
        guard fetchSpeedLimits else { return "Off — pace of the mode" }
        let count = route.speedSamples.count
        if count > 0 { return "\(count) stretches from OpenStreetMap" }
        if let reason = speedLimitFailure { return "Unavailable (\(reason)) — pace of the mode" }
        return "No speed limits — pace of the mode"
    }

    /// Prepares the playback of a route: speed profile and schedule.
    public func select(_ plan: RoutePlan) {
        // Rebuilding the schedule under a running trip used to reset the clock
        // to zero while the task went on playing the previous one: touching the
        // speed toggle ten minutes in sent the iPhone back to the start of the
        // route. Nothing in the interface prevented it, and `speedSettings`
        // calls straight in here on every change. So the ground already covered
        // is measured first, and given back afterwards.
        let sameRoute = selectedRoute?.id == plan.id
        let running = tripState == .playing || tripState == .paused
        let wasPlaying = tripState == .playing
        let coveredDistance = (sameRoute && running)
            ? schedule?.sample(at: tripElapsed).distanceTravelled
            : nil
        if coveredDistance != nil {
            tripTask?.cancel()
            tripTask = nil
        }

        selectedRoute = plan
        guard let geometry = plan.geometry else { return }

        let stops = StopDetector.stops(
            geometry: geometry,
            stepEnds: plan.stepEndArcLengths,
            mode: plan.mode
        )
        let settings = speedSettings.clamped(to: plan.mode)
        // Without an explicit setting, the duration announced by Apple is the
        // reference: it covers traffic, lights and slowdowns, which no speed
        // limit could reflect. It is transposed to the mode when the service
        // computed with a pace other than ours.
        let target = settings.targetDuration(forDistance: plan.distance) ?? plan.targetDuration

        schedule = TripSchedule.calibrated(
            geometry: geometry,
            mode: plan.mode,
            samples: plan.speedSamples,
            stops: stops,
            minimumSpeed: settings.minimumSpeed,
            speedCeiling: settings.speedCeiling(for: plan.mode),
            targetDuration: target
        )
        if let distance = coveredDistance, let schedule {
            tripElapsed = schedule.elapsed(atDistance: distance)
            tripProgress = schedule.duration > 0 ? min(tripElapsed / schedule.duration, 1) : 0
            remainingTime = max(schedule.duration - tripElapsed, 0)
            currentCoordinate = schedule.sample(at: tripElapsed).coordinate
            // The task was cancelled above; restart it on the new schedule.
            if wasPlaying {
                tripState = .ready
                playTrip()
            } else {
                tripState = .paused
            }
        } else {
            tripElapsed = 0
            tripProgress = 0
            remainingTime = schedule?.duration ?? 0
            if let first = schedule?.sample(at: 0) { currentCoordinate = first.coordinate }
        }
    }

    public func playTrip() {
        // Without a link, the trip would scroll nicely across the map without
        // the iPhone moving an inch. Better to refuse outright.
        guard requireConnection() else { return }
        guard let schedule, tripState != .playing else { return }
        stopKeepAlive()
        tripState = .playing
        updateBackgroundHold()

        tripTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            var previous = clock.now
            // We advance a deadline rather than sleeping a full second:
            // otherwise the latency of each send would build up as lateness.
            var deadline = clock.now

            while !Task.isCancelled {
                deadline = deadline.advanced(by: .seconds(self.tickInterval))
                try? await Task.sleep(until: deadline, clock: clock)
                if Task.isCancelled { return }

                let now = clock.now
                // Elapsed time comes from the clock, never from the number of
                // iterations: a send that drags skips a point instead of
                // shifting the trip.
                let delta = previous.duration(to: now)
                previous = now
                self.tripElapsed += Double(delta.components.seconds)
                    + Double(delta.components.attoseconds) * 1e-18

                let fix = schedule.sample(at: self.tripElapsed)
                self.currentCoordinate = fix.coordinate
                self.currentSpeed = fix.speed
                self.currentSpeedLimit = schedule.legalLimit(at: self.tripElapsed)
                self.tripProgress = schedule.duration > 0
                    ? min(self.tripElapsed / schedule.duration, 1)
                    : 1
                self.remainingTime = max(schedule.duration - self.tripElapsed, 0)
                await self.pushCurrent()

                if fix.isFinished || self.tripElapsed >= schedule.duration {
                    self.arriveAtDestination()
                    return
                }
            }
        }
    }

    public func pauseTrip() {
        guard tripState == .playing else { return }
        tripTask?.cancel()
        tripTask = nil
        tripState = .paused
        currentSpeed = 0
        // Paused is still somewhere: without this the device drifted back to
        // its real position while the interface showed the trip on hold.
        startKeepAlive()
    }

    public func stopTrip() {
        tripTask?.cancel()
        tripTask = nil
        stopKeepAlive()
        tripElapsed = 0
        tripProgress = 0
        currentSpeed = 0
        if tripState == .playing || tripState == .paused || tripState == .arrived {
            tripState = schedule == nil ? .idle : .ready
        }
    }

    /// Resets everything: the device gets its real location back, and nothing
    /// is left on the map.
    ///
    /// The order matters: we first give the device its location back, while the
    /// link is still established, before erasing what is displayed.
    public func resetEverything() async {
        await stopEverything()
        if pushedCoordinate != nil {
            try? await backend.clearLocation(settlingNear: realLocation.fix?.coordinate)
            pushedCoordinate = nil
        }
        currentCoordinate = nil
        // Nothing left to hold: give the location radio back.
        realLocation.endBackgroundHold()
        pendingPoint = nil
        customStart = nil
        gpxTrack = nil
        recordedTrack = []
        isRecording = false
        // The route goes first: `speedSettings` has a didSet that calls
        // `select()`, which rebuilds a schedule and puts a coordinate back where
        // one has just been cleared. Resetting used to resurrect the very
        // position it was meant to drop.
        clearRouteKeepingPosition()
        speedSettings = .automatic
        lastError = nil
    }

    /// True as soon as there is something to clear.
    public var hasSomethingToReset: Bool {
        currentCoordinate != nil || pushedCoordinate != nil || pendingPoint != nil
            || destination != nil || customStart != nil || gpxTrack != nil
            || !recordedTrack.isEmpty
    }

    public func clearRoute() {
        stopTrip()
        gpxTrack = nil
        routeCandidates = []
        selectedRoute = nil
        schedule = nil
        destination = nil
        tripState = .idle
    }

    private func arriveAtDestination() {
        tripTask = nil
        tripState = .arrived
        tripProgress = 1
        currentSpeed = 0
        remainingTime = 0
        startKeepAlive()
    }

    /// Holds the location at the destination.
    ///
    /// The developer service maintains nothing by itself: if we stop emitting,
    /// the device eventually finds its real location again. So we push the
    /// coordinate again regularly, with an offset of barely a meter: pushing a
    /// strictly identical coordinate can be ignored.
    private func startKeepAlive() {
        stopKeepAlive()
        guard let anchor = currentCoordinate else { return }

        keepAliveTask = Task { [weak self] in
            var wobble = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                wobble = (wobble + 1) % 4
                let jittered = anchor.destination(
                    bearingDegrees: Double(wobble) * 90,
                    meters: 0.8
                )
                self.currentCoordinate = jittered
                await self.pushCurrent()
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // MARK: - Application lifecycle

    /// Whether the trip was playing when the app left the foreground.
    private var resumeWhenActive = false

    /// Starts or stops the background hold according to whether anything is
    /// currently being held on the device.
    ///
    /// It is not free — the location radio stays on — so it runs only while
    /// there is a position to keep alive, and stops the moment there is not.
    private func updateBackgroundHold() {
        let holding = currentCoordinate != nil
            && (tripState == .playing || tripState == .paused
                || tripState == .arrived || tripState == .idle)
        if holding {
            realLocation.beginBackgroundHold()
        } else {
            realLocation.endBackgroundHold()
        }
    }

    /// The app is leaving the foreground.
    ///
    /// With the hold in place the process keeps running and the trip carries on
    /// — which is the entire point, since the app you actually want to fool is
    /// the one you just switched to.
    ///
    /// Without it, iOS is about to suspend us. Nothing will be emitted and the
    /// device will find its real position again; that part cannot be helped.
    /// What can is the return: `ContinuousClock` counts through a suspension,
    /// so a trip left running comes back having jumped forward by the whole
    /// interval. Pausing keeps the schedule honest.
    public func applicationWillResignActive() {
        if realLocation.isHoldingInBackground { return }
        resumeWhenActive = tripState == .playing
        if resumeWhenActive { pauseTrip() }
        stopKeepAlive()
    }

    /// The app is back in the foreground.
    public func applicationDidBecomeActive() {
        updateBackgroundHold()
        if resumeWhenActive {
            resumeWhenActive = false
            tripState = .paused
            playTrip()
        } else if currentCoordinate != nil, tripState != .playing {
            // Whatever position was being held is very likely gone by now.
            startKeepAlive()
        }
    }

    public func stopEverything() async {
        stopTrip()
    }

    /// Closes the link and gives the iPhone its real location back.
    public func disconnect() async {
        await stopEverything()
        // Clear BEFORE cutting: if we merely close the channel, the device can
        // stay on the last location for a few moments.
        if pushedCoordinate != nil {
            try? await backend.clearLocation(settlingNear: nil)
            pushedCoordinate = nil
        }
        await backend.shutdown()
        status = .idle
    }

    public func shutdown() async {
        await stopEverything()
        await backend.shutdown()
        status = .idle
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
    }
}
