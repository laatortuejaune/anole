import Foundation

/// Class of a road, as OpenStreetMap tags it on the `highway` key.
///
/// Only the classes a route can actually be driven or walked on appear here.
/// Everything else - footways, tracks, driveways parallel to the road - is
/// rejected during matching rather than mapped to something approximate: a
/// route never follows them, and letting an unrelated path win a match is how
/// a motorway ends up capped at walking pace.
public enum RoadClass: String, Sendable, CaseIterable {
    case motorway
    case trunk
    case primary
    case secondary
    case tertiary
    case unclassified
    case residential
    case livingStreet
    case service

    /// Reads the OSM `highway` value. Link ramps fold into their parent class;
    /// the ramp itself is flagged separately, since it carries neither the
    /// speed nor the geometry of the road it joins.
    public static func parse(highway: String) -> (roadClass: RoadClass, isLink: Bool)? {
        switch highway {
        case "motorway": return (.motorway, false)
        case "motorway_link": return (.motorway, true)
        case "trunk": return (.trunk, false)
        case "trunk_link": return (.trunk, true)
        case "primary": return (.primary, false)
        case "primary_link": return (.primary, true)
        case "secondary": return (.secondary, false)
        case "secondary_link": return (.secondary, true)
        case "tertiary": return (.tertiary, false)
        case "tertiary_link": return (.tertiary, true)
        case "unclassified": return (.unclassified, false)
        case "residential": return (.residential, false)
        case "living_street": return (.livingStreet, false)
        case "service": return (.service, false)
        default: return nil
        }
    }

    /// Limit to assume when the segment carries no `maxspeed` tag, in m/s.
    ///
    /// These are the French implicit limits, which match most of continental
    /// Europe. They are a last resort: an explicit tag always wins. Only 17% of
    /// ways carry one in the samples this was checked against, so the fallback
    /// is not an edge case - it is the common path.
    ///
    /// `inBuiltUpArea` resolves the ambiguity of the small classes, which mean
    /// 50 in a town and 80 outside it with nothing in the class to tell them
    /// apart. It is deliberately ignored by the big roads: a motorway does not
    /// drop to 50 because its interchange is lit.
    public func impliedLimit(inBuiltUpArea: Bool = false) -> Double {
        switch self {
        case .motorway: return 130 / 3.6
        case .trunk: return 110 / 3.6
        case .primary, .secondary: return 80 / 3.6
        case .tertiary, .unclassified: return (inBuiltUpArea ? 50 : 80) / 3.6
        case .residential: return 50 / 3.6
        case .livingStreet: return 20 / 3.6
        case .service: return 30 / 3.6
        }
    }

    /// How much of the global calibration this class absorbs.
    ///
    /// The calibration scales every speed until the trip lasts as long as the
    /// routing service says. Applied evenly it is wrong, and visibly so: a trip
    /// that crawls through town and then opens onto a motorway needs 20 minutes
    /// because of the town, yet an even factor takes the same cut out of the
    /// motorway and leaves it doing 58 km/h where the sign says 90.
    ///
    /// Time lost in traffic is lost where the traffic is. So the factor is
    /// raised to this exponent: below 1 on the big roads, which barely move from
    /// their limit whatever the trip does, above 1 in town, which absorbs the
    /// rest. Every value is positive, so the duration still falls monotonically
    /// as the factor grows and the binary search still converges.
    public var scaleSensitivity: Double {
        switch self {
        case .motorway: return 0.2
        case .trunk: return 0.3
        case .primary: return 0.5
        case .secondary: return 0.65
        case .tertiary: return 0.8
        case .unclassified: return 0.95
        case .residential: return 1.15
        case .livingStreet, .service: return 1.3
        }
    }

    /// Share of the limit this class holds no matter what, as a floor.
    ///
    /// The exponent above softens the calibration but never cancels it, and on a
    /// long enough trip a motorway still ended up at 84 for a posted 90. On a
    /// clear motorway you drive at the limit; you drop a kilometre or two below
    /// it now and then, not seven. So the calibration may no longer push these
    /// classes under this floor at all.
    ///
    /// It is a floor on the setpoint, not on the result: bends, junctions and
    /// braking still bring the speed down through it, which is what they are
    /// for. Town classes get no floor - they are what absorbs the delay.
    public var limitFidelity: Double {
        switch self {
        case .motorway: return 0.98
        case .trunk: return 0.96
        case .primary: return 0.88
        case .secondary: return 0.82
        case .tertiary: return 0.75
        case .unclassified: return 0.6
        case .residential, .livingStreet, .service: return 0
        }
    }

    /// Cruising speed actually held on this class, as a fraction of the limit.
    ///
    /// This is not the average speed of the trip: stops and turns are modelled
    /// separately by the planner, and would be counted twice if they were folded
    /// in here. What it captures is the diffuse loss - the traffic you follow,
    /// the merges, the moments you simply are not at the limit. It falls as the
    /// road gets smaller, because that is where the loss concentrates.
    public var flowFactor: Double {
        switch self {
        case .motorway: return 1
        case .trunk: return 0.98
        case .primary: return 0.93
        case .secondary: return 0.90
        case .tertiary: return 0.87
        case .unclassified: return 0.82
        case .residential: return 0.75
        case .livingStreet, .service: return 0.70
        }
    }
}

// MARK: - Reading the maxspeed tag

public enum MaxSpeedTag {

    /// Converts an OSM `maxspeed` value into m/s.
    ///
    /// The tag is free text and the wild forms are common: a bare number means
    /// km/h, `mph` appears across the UK and the US, `none` is the unrestricted
    /// German motorway, and `walk` is a written-out pace. Anything conditional
    /// or signal-driven has no fixed value and is reported as unknown, so the
    /// class fallback takes over instead of inventing a figure.
    public static func parse(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }

        switch value {
        case "walk": return 7 / 3.6
        case "none", "signals", "variable", "unposted": return nil
        default: break
        }

        // Country presets such as "FR:urban" carry no number of their own.
        if value.contains(":") { return implied(preset: value) }

        let parts = value.split(separator: " ").map(String.init)
        guard let number = Double(parts[0]), number > 0 else { return nil }

        if parts.count > 1, parts[1] == "mph" { return number * 1609.344 / 3600 }
        if parts.count > 1, parts[1] == "knots" { return nil }
        return number / 3.6
    }

    /// The handful of country presets worth resolving. The list stays short on
    /// purpose: an unknown preset must fall through to the class fallback
    /// rather than be guessed at.
    private static func implied(preset: String) -> Double? {
        switch preset.split(separator: ":").last.map(String.init) {
        case "urban": return 50 / 3.6
        case "rural": return 80 / 3.6
        case "motorway": return 130 / 3.6
        case "trunk": return 110 / 3.6
        case "living_street": return 20 / 3.6
        case "walk": return 7 / 3.6
        default: return nil
        }
    }
}

// MARK: - Road segments

/// One straight piece of an OSM way, with what is known about its speed.
///
/// Ways are cut into segments before matching because the question asked of
/// them is always local: which piece of road is this point of the track on.
public struct RoadSegment: Sendable, Hashable {
    public var start: Coordinate
    public var end: Coordinate
    public var roadClass: RoadClass
    public var isLink: Bool
    /// Limit read from the tag, in m/s. Nil when the way carried none.
    public var taggedLimit: Double?
    /// Street lighting, read from the `lit` tag. Stands in for "this is a town":
    /// a lit road is a road with houses along it, and it is far better covered
    /// than `maxspeed` is.
    public var isLit: Bool

    public init(
        start: Coordinate,
        end: Coordinate,
        roadClass: RoadClass,
        isLink: Bool = false,
        taggedLimit: Double? = nil,
        isLit: Bool = false
    ) {
        self.start = start
        self.end = end
        self.roadClass = roadClass
        self.isLink = isLink
        self.taggedLimit = taggedLimit
        self.isLit = isLit
    }

    /// Limit to apply: the tag when there is one, the class otherwise.
    ///
    /// A ramp with no tag is capped well below its parent road. A slip road off
    /// a motorway is not driven at 130, and inheriting the parent value blindly
    /// would produce exactly that.
    public var effectiveLimit: Double {
        if let taggedLimit { return taggedLimit }
        let implied = roadClass.impliedLimit(inBuiltUpArea: isLit)
        return isLink ? min(implied, 70 / 3.6) : implied
    }

    public var bearing: Double { start.bearing(to: end) }
}
