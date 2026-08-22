import Foundation

/// Extraction of coordinates from a link copied out of a browser or an app.
///
/// Pasting the URL of a place is the most natural move once the spot has been
/// found somewhere else. Every service encodes the location its own way, and
/// some put several of them in the same address: the order tried below runs
/// from the most precise (the place being pointed at) to the roughest (the map
/// camera).
public enum CoordinateURL {

    public static func extract(from text: String) -> Coordinate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") || trimmed.hasPrefix("geo:") else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }

        let queryItems = components.queryItems ?? []
        func query(_ names: String...) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.lowercased() == name })?.value,
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        // 1. Google encodes the place being pointed at in the !3d (latitude) and
        //    !4d (longitude) fields of the path. That is the spot actually aimed
        //    at, unlike @ which is only the framing of the camera.
        if let place = googlePlace(in: trimmed) { return place }

        // 2. Apple Maps and geo: give the location in plain form.
        if let value = query("ll", "coordinate", "sll", "daddr"),
           let coordinate = pair(from: value) {
            return coordinate
        }
        if trimmed.hasPrefix("geo:") {
            let body = trimmed.dropFirst(4).split(separator: "?").first.map(String.init) ?? ""
            if let coordinate = pair(from: body) { return coordinate }
        }

        // 3. OpenStreetMap marks the pinned point with mlat/mlon.
        if let latitude = query("mlat"), let longitude = query("mlon"),
           let coordinate = pair(from: "\(latitude),\(longitude)") {
            return coordinate
        }

        // 4. Some links stash coordinates inside the text query.
        if let value = query("q", "query"), let coordinate = pair(from: value) {
            return coordinate
        }

        // 5. OpenStreetMap fragment: #map=zoom/lat/lon. The first number is the
        //    zoom level, most definitely not a latitude.
        if let fragment = components.fragment, fragment.contains("map=") {
            let digits = fragment
                .replacingOccurrences(of: "map=", with: "")
                .split(whereSeparator: { $0 == "/" })
            if digits.count >= 3,
               let coordinate = pair(from: "\(digits[1]),\(digits[2])") {
                return coordinate
            }
        }

        // 6. As a last resort, the framing of the Google camera: @lat,lon,zoom.
        if let at = cameraPosition(in: trimmed) { return at }

        return nil
    }

    /// `!3d<latitude>!4d<longitude>`, the place Google actually points at.
    private static func googlePlace(in text: String) -> Coordinate? {
        guard let latitude = number(after: "!3d", in: text),
              let longitude = number(after: "!4d", in: text) else { return nil }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }

    /// `@<latitude>,<longitude>,<zoom>z`, the Google camera.
    private static func cameraPosition(in text: String) -> Coordinate? {
        guard let atIndex = text.firstIndex(of: "@") else { return nil }
        let tail = text[text.index(after: atIndex)...]
        let pieces = tail.split(separator: ",")
        guard pieces.count >= 2 else { return nil }
        return pair(from: "\(pieces[0]),\(pieces[1])")
    }

    private static func number(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        var digits = ""
        for character in text[range.upperBound...] {
            if character.isNumber || character == "." || character == "-" {
                digits.append(character)
            } else {
                break
            }
        }
        return Double(digits)
    }

    /// Reuses the text parser: once the pair is isolated, the validation and
    /// recovery rules are exactly the same.
    private static func pair(from value: String) -> Coordinate? {
        let cleaned = value.removingPercentEncoding ?? value
        return CoordinateParser.parse(cleaned)
    }
}
