import Testing
import Foundation
@testable import AnoleCore

@Suite("Speed limits")
struct SpeedLimitsTests {

    // MARK: - Reading the tag

    @Test("A bare number is km/h")
    func plainNumber() {
        #expect(MaxSpeedTag.parse("50") == 50 / 3.6)
        #expect(MaxSpeedTag.parse(" 90 ") == 90 / 3.6)
    }

    @Test("Miles per hour are converted")
    func milesPerHour() {
        let parsed = MaxSpeedTag.parse("30 mph")
        #expect(parsed != nil)
        #expect(abs((parsed ?? 0) - 30 * 1609.344 / 3600) < 1e-9)
    }

    @Test("Country presets resolve to their implied limit")
    func presets() {
        #expect(MaxSpeedTag.parse("FR:urban") == 50 / 3.6)
        #expect(MaxSpeedTag.parse("DE:motorway") == 130 / 3.6)
        #expect(MaxSpeedTag.parse("FR:living_street") == 20 / 3.6)
    }

    /// An unrestricted or sign-driven road has no figure to give. Reporting it
    /// as unknown hands the decision to the class fallback; inventing a number
    /// here would silently cap a German motorway at whatever we made up.
    @Test("Values with no fixed figure are unknown, not zero")
    func unknownValues() {
        #expect(MaxSpeedTag.parse("none") == nil)
        #expect(MaxSpeedTag.parse("signals") == nil)
        #expect(MaxSpeedTag.parse("variable") == nil)
        #expect(MaxSpeedTag.parse("") == nil)
        #expect(MaxSpeedTag.parse("nonsense") == nil)
        #expect(MaxSpeedTag.parse("50 knots") == nil)
        #expect(MaxSpeedTag.parse("XX:unheard_of") == nil)
    }

    @Test("Walk is a written-out pace")
    func walkTag() {
        #expect(MaxSpeedTag.parse("walk") == 7 / 3.6)
    }

    // MARK: - Road classes

    @Test("Link ramps fold into their parent but stay flagged")
    func linkParsing() {
        #expect(RoadClass.parse(highway: "motorway")?.roadClass == .motorway)
        #expect(RoadClass.parse(highway: "motorway")?.isLink == false)
        #expect(RoadClass.parse(highway: "motorway_link")?.roadClass == .motorway)
        #expect(RoadClass.parse(highway: "motorway_link")?.isLink == true)
    }

    @Test("Paths a route never follows are rejected outright")
    func rejectedClasses() {
        #expect(RoadClass.parse(highway: "footway") == nil)
        #expect(RoadClass.parse(highway: "cycleway") == nil)
        #expect(RoadClass.parse(highway: "track") == nil)
        #expect(RoadClass.parse(highway: "") == nil)
    }

    @Test("The tag wins over the class")
    func taggedWins() {
        let segment = RoadSegment(
            start: Coordinate(latitude: 37.77, longitude: -122.41),
            end: Coordinate(latitude: 37.78, longitude: -122.41),
            roadClass: .motorway,
            taggedLimit: 90 / 3.6
        )
        #expect(segment.effectiveLimit == 90 / 3.6)
    }

    /// A slip road off a motorway is not driven at 130. Inheriting the parent
    /// limit untouched is the one fallback mistake that would be felt.
    @Test("An untagged ramp is capped well below its parent road")
    func untaggedRamp() {
        let base = Coordinate(latitude: 37.77, longitude: -122.41)
        let road = RoadSegment(
            start: base, end: base.destination(bearingDegrees: 90, meters: 100),
            roadClass: .motorway
        )
        let ramp = RoadSegment(
            start: base, end: base.destination(bearingDegrees: 90, meters: 100),
            roadClass: .motorway, isLink: true
        )
        #expect(road.effectiveLimit == 130 / 3.6)
        #expect(ramp.effectiveLimit == 70 / 3.6)
    }

    /// Only 17% of French ways carry a maxspeed, so what the class assumes in
    /// its absence matters more than the tag does. Street lighting is the one
    /// widely tagged signal that separates a village street from a country road.
    @Test("Street lighting settles the ambiguous classes")
    func builtUpAreaHint() {
        #expect(RoadClass.unclassified.impliedLimit(inBuiltUpArea: false) == 80 / 3.6)
        #expect(RoadClass.unclassified.impliedLimit(inBuiltUpArea: true) == 50 / 3.6)
        #expect(RoadClass.tertiary.impliedLimit(inBuiltUpArea: true) == 50 / 3.6)
    }

    /// A lit interchange is still a motorway.
    @Test("The big roads ignore the lighting")
    func bigRoadsIgnoreLighting() {
        #expect(RoadClass.motorway.impliedLimit(inBuiltUpArea: true) == 130 / 3.6)
        #expect(RoadClass.trunk.impliedLimit(inBuiltUpArea: true) == 110 / 3.6)
    }

    @Test("A tagged limit wins over the lighting too")
    func taggedBeatsLighting() {
        let base = Coordinate(latitude: 37.77, longitude: -122.41)
        let segment = RoadSegment(
            start: base, end: base.destination(bearingDegrees: 90, meters: 100),
            roadClass: .unclassified, taggedLimit: 70 / 3.6, isLit: true
        )
        #expect(segment.effectiveLimit == 70 / 3.6)
    }

    @Test("An unlit country road keeps the rural limit")
    func unlitStaysRural() {
        let base = Coordinate(latitude: 37.77, longitude: -122.41)
        let segment = RoadSegment(
            start: base, end: base.destination(bearingDegrees: 90, meters: 100),
            roadClass: .unclassified
        )
        #expect(segment.effectiveLimit == 80 / 3.6)
    }

    // MARK: - Point to segment

    @Test("Distance to a segment is measured to the nearest point on it")
    func pointToSegment() {
        let a = LocalPlane.Point(x: 0, y: 0)
        let b = LocalPlane.Point(x: 100, y: 0)

        #expect(distance(from: LocalPlane.Point(x: 50, y: 0), toSegment: a, b) == 0)
        #expect(abs(distance(from: LocalPlane.Point(x: 50, y: 12), toSegment: a, b) - 12) < 1e-9)
        // Past the end, the foot is clamped: the distance is to the endpoint.
        #expect(abs(distance(from: LocalPlane.Point(x: 130, y: 0), toSegment: a, b) - 30) < 1e-9)
    }

    @Test("A segment whose ends coincide still answers")
    func degenerateSegment() {
        let a = LocalPlane.Point(x: 10, y: 10)
        #expect(abs(distance(from: LocalPlane.Point(x: 13, y: 14), toSegment: a, a) - 5) < 1e-9)
    }

    // MARK: - Matching

    let origin = Coordinate(latitude: 37.7793, longitude: -122.4193)

    func track(bearing: Double, meters: Double) -> PathGeometry {
        PathGeometry([origin, origin.destination(bearingDegrees: bearing, meters: meters)])!
    }

    /// A road drawn as OSM would: a chain of short straight pieces.
    func road(
        from start: Coordinate,
        bearing: Double,
        length: Double,
        roadClass: RoadClass,
        limit: Double?
    ) -> [RoadSegment] {
        var result: [RoadSegment] = []
        var current = start
        var walked = 0.0
        while walked < length {
            let piece = min(50, length - walked)
            let next = current.destination(bearingDegrees: bearing, meters: piece)
            result.append(
                RoadSegment(start: current, end: next, roadClass: roadClass, taggedLimit: limit)
            )
            current = next
            walked += piece
        }
        return result
    }

    @Test("A single road gives one sample carrying its limit")
    func uniformRoad() {
        let geometry = track(bearing: 90, meters: 1000)
        let segments = road(from: origin, bearing: 90, length: 1000, roadClass: .trunk, limit: 110 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)

        #expect(samples.count == 1)
        #expect(samples.first?.legalLimit == 110 / 3.6)
        // The travel speed sits below the limit: the flow factor for the class.
        #expect(samples.first.map { $0.travelSpeed < $0.legalLimit! } == true)
    }

    @Test("A change of limit along the way splits the samples")
    func changingLimit() {
        let geometry = track(bearing: 90, meters: 2000)
        let middle = origin.destination(bearingDegrees: 90, meters: 1000)
        let segments =
            road(from: origin, bearing: 90, length: 1000, roadClass: .motorway, limit: 130 / 3.6)
            + road(from: middle, bearing: 90, length: 1000, roadClass: .residential, limit: 50 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)

        #expect(samples.count == 2)
        #expect(samples.first?.legalLimit == 130 / 3.6)
        #expect(samples.last?.legalLimit == 50 / 3.6)
        // The break lands where the road changes, within one probe spacing.
        #expect(abs((samples.first?.endArcLength ?? 0) - 1000) <= SpeedLimitMatcher.probeSpacing)
    }

    /// At a junction the crossing road passes right through the track. On
    /// distance alone it wins the match and drops its own limit across the
    /// middle of the trip.
    @Test("A road crossing the track does not steal the match")
    func crossingRoadRejected() {
        let geometry = track(bearing: 90, meters: 1000)
        let junction = origin.destination(bearingDegrees: 90, meters: 500)
        let mainRoad = road(from: origin, bearing: 90, length: 1000, roadClass: .trunk, limit: 110 / 3.6)
        let crossing = road(
            from: junction.destination(bearingDegrees: 0, meters: 100),
            bearing: 180, length: 200, roadClass: .residential, limit: 30 / 3.6
        )

        let samples = SpeedLimitMatcher.samples(
            geometry: geometry, segments: mainRoad + crossing, mode: .driving
        )

        #expect(samples.count == 1)
        #expect(samples.first?.legalLimit == 110 / 3.6)
    }

    /// A node no sample covers is a node with no limit, and the planner lets it
    /// accelerate freely. Built from probe positions alone, the runs left one
    /// spacing uncovered at every change of limit - enough for the car to be
    /// seen doing 92 on a road posted at 90.
    @Test("The samples cover the track without a gap")
    func samplesAreContiguous() {
        let geometry = track(bearing: 90, meters: 3000)
        let first = origin.destination(bearingDegrees: 90, meters: 1000)
        let second = origin.destination(bearingDegrees: 90, meters: 2000)
        let segments =
            road(from: origin, bearing: 90, length: 1000, roadClass: .motorway, limit: 90 / 3.6)
            + road(from: first, bearing: 90, length: 1000, roadClass: .residential, limit: 50 / 3.6)
            + road(from: second, bearing: 90, length: 1000, roadClass: .trunk, limit: 110 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)
        #expect(samples.count >= 2)
        for (previous, next) in zip(samples, samples.dropFirst()) {
            #expect(next.startArcLength == previous.endArcLength)
        }
    }

    /// The consequence the gap had on the trip itself.
    @Test("No node is ever driven above its own limit")
    func neverAboveTheLimit() {
        let geometry = track(bearing: 90, meters: 6000)
        let middle = origin.destination(bearingDegrees: 90, meters: 3000)
        let segments =
            road(from: origin, bearing: 90, length: 3000, roadClass: .motorway, limit: 90 / 3.6)
            + road(from: middle, bearing: 90, length: 3000, roadClass: .motorway, limit: 90 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)
        // A target so short the calibration saturates and pushes everywhere.
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, samples: samples, targetDuration: 60
        )
        var peak = 0.0
        var elapsed = 0.0
        while elapsed <= schedule.duration {
            peak = max(peak, schedule.sample(at: elapsed).speed)
            elapsed += 0.5
        }
        #expect(peak <= 90 / 3.6 + 0.01)
    }

    @Test("Nothing to match on gives nothing, rather than a made-up limit")
    func noSegments() {
        let geometry = track(bearing: 90, meters: 500)
        #expect(SpeedLimitMatcher.samples(geometry: geometry, segments: [], mode: .driving).isEmpty)
    }

    /// A road limit says nothing about the pace of a pedestrian, and the mode
    /// ceiling would flatten every node to the same value anyway - losing the
    /// variation the calibration exists to produce.
    @Test("Only driving gets limits")
    func drivingOnly() {
        let geometry = track(bearing: 90, meters: 1000)
        let segments = road(from: origin, bearing: 90, length: 1000, roadClass: .residential, limit: 50 / 3.6)

        #expect(SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .walking).isEmpty)
        #expect(SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .cycling).isEmpty)
        #expect(!SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving).isEmpty)
    }

    @Test("A gap in the data is bridged, not left as a hole")
    func gapsFilled() {
        var matched: [Int?] = [nil, 3, nil, nil, 7, nil]
        SpeedLimitMatcher.fillGaps(&matched)
        #expect(matched == [3, 3, 3, 3, 7, 7])
    }

    @Test("With nothing matched at all, filling invents nothing")
    func gapsAllEmpty() {
        var matched: [Int?] = [nil, nil, nil]
        SpeedLimitMatcher.fillGaps(&matched)
        #expect(matched == [nil, nil, nil])
    }

    /// A handful of probes stolen by a neighbouring road would otherwise show up
    /// as the car braking hard and accelerating again for no visible reason.
    @Test("A stretch too short to be a real road change is absorbed")
    func shortRunAbsorbed() {
        let geometry = track(bearing: 90, meters: 1000)
        let intruderStart = origin.destination(bearingDegrees: 90, meters: 500)
        var segments = road(from: origin, bearing: 90, length: 1000, roadClass: .trunk, limit: 110 / 3.6)
        // Same heading, sitting exactly on the track over a very short stretch.
        segments += road(from: intruderStart, bearing: 90, length: 30, roadClass: .residential, limit: 30 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)
        #expect(samples.allSatisfy { $0.legalLimit == 110 / 3.6 })
    }

    // MARK: - Effect on the trip

    /// The whole point of the exercise: the limit has to reach the moving point.
    @Test("The motorway stretch is driven faster than the town stretch")
    func profileFollowsTheLimits() {
        let geometry = track(bearing: 90, meters: 4000)
        let middle = origin.destination(bearingDegrees: 90, meters: 2000)
        let segments =
            road(from: origin, bearing: 90, length: 2000, roadClass: .motorway, limit: 130 / 3.6)
            + road(from: middle, bearing: 90, length: 2000, roadClass: .residential, limit: 50 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, samples: samples,
            targetDuration: 200
        )

        let onMotorway = schedule.sample(at: schedule.duration * 0.25).speed
        let inTown = schedule.sample(at: schedule.duration * 0.9).speed
        #expect(onMotorway > inTown)
        // And neither exceeds what its own road allows.
        #expect(inTown <= 50 / 3.6 + 0.01)
    }

    /// The bug this was written for: a trip slow because of its town centre was
    /// taking the same cut out of the motorway, which ended up doing 58 where
    /// the sign said 90. Time lost in traffic has to be lost where the traffic
    /// is.
    @Test("The motorway keeps close to its limit while the town absorbs the delay")
    func townAbsorbsTheDelay() {
        let geometry = track(bearing: 90, meters: 11_000)
        let junction = origin.destination(bearingDegrees: 90, meters: 3000)
        let segments =
            road(from: origin, bearing: 90, length: 3000, roadClass: .residential, limit: 30 / 3.6)
            + road(from: junction, bearing: 90, length: 8000, roadClass: .motorway, limit: 90 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)
        // A pace the town alone explains: 11 km in 20 minutes.
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, samples: samples, targetDuration: 20 * 60
        )

        let inTown = schedule.sample(at: schedule.duration * 0.35).speed
        let onMotorway = schedule.sample(at: schedule.duration * 0.85).speed

        // The motorway holds a far larger share of its own limit than the town.
        #expect(onMotorway / (90 / 3.6) > 0.7)
        #expect(inTown / (30 / 3.6) < 0.7)
        // And the announced duration is still met.
        #expect(abs(schedule.duration - 20 * 60) < 5)
    }

    /// Asked for: on a motorway the speed must sit on the limit, dropping a
    /// kilometre or two below it now and then - not seven.
    @Test("A motorway is driven at its limit even when the trip is slow overall")
    func motorwayHoldsItsLimit() {
        let geometry = track(bearing: 90, meters: 12_000)
        let junction = origin.destination(bearingDegrees: 90, meters: 3000)
        let segments =
            road(from: origin, bearing: 90, length: 3000, roadClass: .residential, limit: 30 / 3.6)
            + road(from: junction, bearing: 90, length: 9000, roadClass: .motorway, limit: 90 / 3.6)

        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)
        // A duration slow enough that the old calibration held the motorway at 84.
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, samples: samples, targetDuration: 25 * 60
        )

        // Sampled by distance, not by time: the town eats three quarters of the
        // duration, so half way through the clock the car is still on the ramp.
        // The window skips the entry and the final braking, which are physics
        // rather than calibration.
        var lowest = Double.greatestFiniteMagnitude
        var elapsed = 0.0
        while elapsed < schedule.duration {
            let fix = schedule.sample(at: elapsed)
            if fix.distanceTravelled > 4500, fix.distanceTravelled < 11_000 {
                lowest = min(lowest, fix.speed)
            }
            elapsed += 1
        }
        #expect(lowest >= 88 / 3.6)
        #expect(lowest <= 90 / 3.6 + 0.01)
    }

    @Test("Town roads keep no floor: they are what absorbs the delay")
    func townHasNoFloor() {
        #expect(RoadClass.residential.limitFidelity == 0)
        #expect(RoadClass.livingStreet.limitFidelity == 0)
        #expect(RoadClass.motorway.limitFidelity > 0.95)
    }

    @Test("With no samples the calibration is the plain multiplication it always was")
    func noSamplesUnchanged() {
        let geometry = track(bearing: 90, meters: 5000)
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, samples: [], targetDuration: 400
        )
        #expect(abs(schedule.duration - 400) < 2)
        #expect(schedule.hasSpeedLimits == false)
    }

    @Test("A trip built on real limits says so")
    func reportsWhetherLimitsAreKnown() {
        let geometry = track(bearing: 90, meters: 2000)
        let segments = road(from: origin, bearing: 90, length: 2000, roadClass: .trunk, limit: 110 / 3.6)
        let samples = SpeedLimitMatcher.samples(geometry: geometry, segments: segments, mode: .driving)
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, samples: samples, targetDuration: 120
        )
        #expect(schedule.hasSpeedLimits)
        #expect(schedule.legalLimit(at: 60) == 110 / 3.6)
    }

    @Test("Without limits the trip still runs, on the pace of the mode")
    func noLimitsStillRuns() {
        let geometry = track(bearing: 90, meters: 4000)
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, samples: [], targetDuration: 300
        )
        #expect(schedule.duration > 0)
        #expect(abs(schedule.duration - 300) < 2)
    }
}

@Suite("Route preparation phases")
struct RoutePhaseTests {

    /// The bar must never go backwards between steps, and must not leave a gap
    /// it would have to jump across.
    @Test("The phases tile the whole bar, in order")
    func phasesTile() {
        let phases = RoutePhase.allCases
        #expect(phases.first?.startFraction == 0)
        #expect(phases.last?.ceilingFraction == 1)

        for phase in phases {
            #expect(phase.startFraction < phase.ceilingFraction)
            #expect(phase.expectedDuration > 0)
        }
        for (previous, next) in zip(phases, phases.dropFirst()) {
            #expect(previous.ceilingFraction == next.startFraction)
        }
    }

    @Test("Every phase says what it is doing")
    func phasesAreNamed() {
        for phase in RoutePhase.allCases {
            #expect(!phase.label.isEmpty)
        }
    }
}
