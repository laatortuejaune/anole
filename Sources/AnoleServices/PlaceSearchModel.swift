import Foundation
import MapKit
import AnoleCore

/// A suggestion offered to the user while typing.
public struct PlaceSuggestion: Identifiable, Hashable {
    public enum Kind: Hashable {
        /// Coordinate read straight from the input: no request needed.
        case direct(Coordinate)
        /// Apple suggestion: a request will be needed to know its location.
        case completion(MKLocalSearchCompletion)
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: Kind

    public var isDirect: Bool {
        if case .direct = kind { return true }
        return false
    }
}

/// Place search: typed coordinates, pasted links, addresses and known places.
@MainActor
public final class PlaceSearchModel: NSObject, ObservableObject {

    @Published public var query = "" {
        didSet { queryChanged() }
    }
    @Published public private(set) var suggestions: [PlaceSuggestion] = []
    @Published public private(set) var isResolving = false
    @Published public private(set) var message: String?

    /// Visible region of the map, to favor nearby results.
    public var biasRegion: MKCoordinateRegion?

    private let completer = MKLocalSearchCompleter()

    public override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    // MARK: - Input

    private func queryChanged() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        message = nil

        guard !text.isEmpty else {
            completer.cancel()
            suggestions = []
            return
        }

        // A coordinate or a link resolves on the spot, without the network: we
        // offer it immediately and do not query Apple for it.
        if let coordinate = CoordinateParser.parse(text) {
            completer.cancel()
            suggestions = [
                PlaceSuggestion(
                    id: "direct",
                    title: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                    subtitle: "Coordinates recognized",
                    kind: .direct(coordinate)
                )
            ]
            return
        }

        if let biasRegion { completer.region = Self.sanitize(biasRegion) }
        // No homemade debounce: the completer already waits for the typing to
        // settle before hitting the network.
        completer.queryFragment = text
    }

    // MARK: - Resolution

    /// Returns the location of a suggestion, querying Apple if necessary.
    public func resolve(_ suggestion: PlaceSuggestion) async -> Coordinate? {
        if case .direct(let coordinate) = suggestion.kind { return coordinate }
        guard case .completion(let completion) = suggestion.kind else { return nil }

        isResolving = true
        defer { isResolving = false }

        do {
            // The specialized initializer ties the search to the exact
            // suggestion; rebuilding a request from the displayed title
            // produces attribution failures.
            let request = MKLocalSearch.Request(completion: completion)
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                message = "Place not found."
                return nil
            }
            return Self.coordinate(of: item)
        } catch {
            message = Self.describe(error)
            return nil
        }
    }

    /// Search started on submit, without going through a suggestion.
    ///
    /// Two concurrent requests: one constrained to the visible map, the other
    /// free. Without the first, "bakery" returns results on the other side of
    /// the country; without the second, "Eiffel Tower" from the Bay Area returns
    /// an absurd local hamlet. The union of the two covers both intentions.
    public func searchDirectly() async -> Coordinate? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let coordinate = CoordinateParser.parse(text) { return coordinate }

        isResolving = true
        defer { isResolving = false }

        async let local = Self.run(text, region: biasRegion.map(Self.sanitize), constrained: true)
        async let global = Self.run(text, region: nil, constrained: false)
        let (localItems, globalItems) = await (local, global)

        if let first = localItems.first ?? globalItems.first {
            return Self.coordinate(of: first)
        }
        message = "No place matches \"\(text)\"."
        return nil
    }

    nonisolated private static func run(
        _ text: String,
        region: MKCoordinateRegion?,
        constrained: Bool
    ) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let region {
            request.region = region
            // Only this setting really biases the search; filling in the region
            // without it has almost no effect. It exists only from macOS 15 and
            // iOS 18 on.
            if constrained, #available(macOS 15.0, iOS 18.0, *) {
                request.regionPriority = .required
            }
        }
        // One instance per request: two concurrent starts on the same instance
        // fail.
        return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }

    // MARK: - Utilities

    nonisolated private static func coordinate(of item: MKMapItem) -> Coordinate {
        // `placemark` is deprecated from macOS 26 on in favor of `location`,
        // but it remains the only path available below that version.
        let point: CLLocationCoordinate2D
        if #available(macOS 26.0, iOS 26.0, *) {
            point = item.location.coordinate
        } else {
            point = item.placemark.coordinate
        }
        return Coordinate(latitude: point.latitude, longitude: point.longitude)
    }

    /// An out-of-bounds region degrades the results without the slightest message.
    nonisolated static func sanitize(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        let latitudeDelta = min(max(region.span.latitudeDelta, 0.002), 60)
        let longitudeDelta = min(max(region.span.longitudeDelta, 0.002), 60)
        let latitude = min(max(region.center.latitude, -90 + latitudeDelta / 2), 90 - latitudeDelta / 2)
        let longitude = min(max(region.center.longitude, -180 + longitudeDelta / 2), 180 - longitudeDelta / 2)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    /// Reorders the suggestions by closeness to what was typed.
    ///
    /// The service returns its results in an order of its own, and the exact
    /// match does not always come out on top: a street with a similar name can
    /// end up ahead of the one written word for word.
    nonisolated static func ranked(
        _ results: [MKLocalSearchCompletion],
        for query: String
    ) -> [MKLocalSearchCompletion] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return results }

        return results.enumerated()
            .map { index, completion -> (Int, Int, MKLocalSearchCompletion) in
                (score(completion, needle: needle), index, completion)
            }
            // On equal scores, the service's original order prevails.
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }

    private nonisolated static func score(_ completion: MKLocalSearchCompletion, needle: String) -> Int {
        let title = normalize(completion.title)
        let full = normalize(completion.title + " " + completion.subtitle)

        if title == needle { return 100 }
        if title.hasPrefix(needle) { return 80 }
        if full.hasPrefix(needle) { return 60 }

        // Do all the typed words show up in the result?
        let words = needle.split(separator: " ").map(String.init)
        let matched = words.filter { full.contains($0) }.count
        if matched == words.count, !words.isEmpty { return 40 }
        return matched * 5
    }

    /// Compares without caring about accents, case or punctuation.
    private nonisolated static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        // rawValue is a UInt whereas NSError.code is an Int.
        guard ns.domain == MKErrorDomain, let code = MKError.Code(rawValue: UInt(ns.code)) else {
            return ns.localizedDescription
        }
        switch code {
        case .placemarkNotFound, .directionsNotFound:
            // "No results" arrives as an error, not as an empty list.
            return "No place matches."
        case .loadingThrottled:
            return "Too many searches in a row. Wait a few seconds."
        case .serverFailure:
            return "The map service is not responding."
        default:
            return ns.localizedDescription
        }
    }
}

extension PlaceSearchModel: MKLocalSearchCompleterDelegate {

    // The callbacks arrive on the main queue but are not annotated as such in
    // the SDK: we explicitly hop back onto the main actor.
    public nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated {
            let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
            self.suggestions = Self.ranked(results, for: query).prefix(8).map { completion in
                PlaceSuggestion(
                    id: "c:\(completion.title)|\(completion.subtitle)",
                    title: completion.title,
                    subtitle: completion.subtitle,
                    kind: .completion(completion)
                )
            }
        }
    }

    public nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        let text = Self.describe(error)
        MainActor.assumeIsolated {
            self.suggestions = []
            self.message = text
        }
    }
}
