import Foundation

/// Recognition of coordinates typed or pasted by hand.
///
/// The goal is to accept whatever copying from Apple Maps, Google Maps or
/// OpenStreetMap gives, without ever guessing when the input really is ambiguous:
/// silently setting a wrong location would be worse than refusing.
public enum CoordinateParser {

    /// Returns a coordinate if the input describes one unambiguously, otherwise `nil`.
    public static func parse(_ input: String) -> Coordinate? {
        // A pasted link is recognized before any text analysis: its digits are
        // buried in path segments that have nothing of a coordinate about them.
        if let fromURL = CoordinateURL.extract(from: input) { return fromURL }

        let text = normalize(input)
        guard !text.isEmpty else { return nil }

        // Hemisphere markers lift every ambiguity: handle them first.
        if text.contains(where: { "NSEWO".contains($0) }) {
            return parseWithHemispheres(text)
        }
        return parseSigned(text)
    }

    // MARK: - Normalization

    private static func normalize(_ input: String) -> String {
        var text = input.uppercased()

        // Typographic apostrophes and quotes, degree symbol, non-breaking spaces:
        // everything a copy-paste drags along without anyone seeing it.
        let substitutions: [(String, String)] = [
            ("\u{2032}", "'"), ("\u{2019}", "'"), ("\u{00B4}", "'"),
            ("\u{2033}", "\""), ("\u{201D}", "\""), ("\u{201C}", "\""),
            ("\u{00A0}", " "), ("\u{202F}", " "), ("\u{2007}", " "),
            ("\u{2013}", "-"), ("\u{2212}", "-"),
            ("\u{00B0}", " "),
        ]
        for (from, to) in substitutions {
            text = text.replacingOccurrences(of: from, with: to)
        }
        // French "OUEST" shares its initial with "O"; align it on W.
        text = text.replacingOccurrences(of: "O", with: "W")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Signed form, without hemisphere marker

    private static func parseSigned(_ text: String) -> Coordinate? {
        guard let (left, right) = splitInTwo(text) else { return nil }
        guard let latitude = degrees(from: left), let longitude = degrees(from: right) else {
            return nil
        }
        return validated(latitude: latitude, longitude: longitude)
    }

    /// Cuts the input in two halves. This is where the ambiguity of the French
    /// decimal comma plays out: "37,7793, -122,4193" holds three commas, whereas
    /// the English form "37.7793, -122.4193" holds only one.
    private static func splitInTwo(_ text: String) -> (String, String)? {
        let commaCount = text.filter { $0 == "," }.count

        // Explicit separator: no ambiguity left, the comma is a decimal point.
        if let index = text.firstIndex(where: { $0 == ";" || $0 == "/" || $0 == "|" }) {
            return halves(text, at: index, decimalComma: true)
        }

        switch commaCount {
        case 0:
            // Two numbers separated by spaces.
            guard let index = separatorIndexOutsideNumber(text) else { return nil }
            return halves(text, at: index, decimalComma: false)
        case 1:
            guard let index = text.firstIndex(of: ",") else { return nil }
            return halves(text, at: index, decimalComma: false)
        case 3:
            // French form: each number carries its own comma, plus the separator.
            // Cut on the second comma, the one that separates the two numbers.
            let positions = text.indices.filter { text[$0] == "," }
            return halves(text, at: positions[1], decimalComma: true)
        default:
            // Two commas, or more: there is no honest way to decide.
            return nil
        }
    }

    private static func halves(
        _ text: String,
        at index: String.Index,
        decimalComma: Bool
    ) -> (String, String) {
        var left = String(text[text.startIndex..<index])
        var right = String(text[text.index(after: index)...])
        if decimalComma {
            left = left.replacingOccurrences(of: ",", with: ".")
            right = right.replacingOccurrences(of: ",", with: ".")
        }
        return (left, right)
    }

    /// Finds the space that separates two numbers, ignoring those internal to a
    /// degrees-minutes-seconds notation.
    private static func separatorIndexOutsideNumber(_ text: String) -> String.Index? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return text.firstIndex(of: " ")
    }

    // MARK: - Form with hemisphere markers

    private static func parseWithHemispheres(_ text: String) -> Coordinate? {
        var latitude: Double?
        var longitude: Double?

        for component in hemisphereComponents(text) {
            guard var value = degrees(from: component.numbers) else { return nil }
            // An explicit sign on top of the hemisphere: keep the absolute value,
            // the hemisphere has the last word.
            value = abs(value)

            switch component.hemisphere {
            case "N": if latitude != nil { return nil }; latitude = value
            case "S": if latitude != nil { return nil }; latitude = -value
            case "E": if longitude != nil { return nil }; longitude = value
            case "W": if longitude != nil { return nil }; longitude = -value
            default: return nil
            }
        }

        guard let latitude, let longitude else { return nil }
        return validated(latitude: latitude, longitude: longitude)
    }

    /// Splits the input around the hemisphere letters, whether they come before
    /// or after the digits. The latitude/longitude order then stops mattering:
    /// "W122.4193 N37.7793" is just as valid as "37.7793N 122.4193W".
    private static func hemisphereComponents(_ text: String) -> [(hemisphere: Character, numbers: String)] {
        var result: [(Character, String)] = []
        var buffer = ""
        var pendingHemisphere: Character?

        func flush(_ hemisphere: Character) {
            // The buffer carries along the separators met on the way: without this
            // cleanup, "37.7793N, 122.4193W" would leave a comma stuck to the second
            // number and the conversion would fail.
            let separators = CharacterSet(charactersIn: " ,;/|")
            let numbers = buffer.trimmingCharacters(in: separators)
            if !numbers.isEmpty, numbers.contains(where: \.isNumber) {
                result.append((hemisphere, numbers))
                buffer = ""
            }
        }

        for character in text {
            if "NSEW".contains(character) {
                if let pending = pendingHemisphere, buffer.contains(where: \.isNumber) {
                    // A prefix already claimed the number being read, and the
                    // letter arriving now opens the next half - it does not
                    // relabel the previous one. Without this, "N37.7793
                    // W122.4193" handed 37.7793 to the W and 122.4193 to the N,
                    // and `validated` then "repaired" the impossible latitude by
                    // swapping the pair: the Indian Ocean, silently, instead of
                    // San Francisco.
                    flush(pending)
                    pendingHemisphere = character
                } else if buffer.contains(where: \.isNumber) {
                    flush(character)          // hemisphere as a suffix
                } else {
                    pendingHemisphere = character   // hemisphere as a prefix
                    buffer = ""
                }
            } else {
                buffer.append(character)
                // A prefix resolves as soon as the next separator turns up.
                if let hemisphere = pendingHemisphere,
                   character == "," || character == ";",
                   buffer.contains(where: \.isNumber) {
                    flush(hemisphere)
                    pendingHemisphere = nil
                }
            }
        }
        if let hemisphere = pendingHemisphere, buffer.contains(where: \.isNumber) {
            flush(hemisphere)
        }
        return result.map { (hemisphere: $0.0, numbers: $0.1) }
    }

    // MARK: - Converting one half into degrees

    /// Accepts "37.7793", "37 46 45.5" (degrees minutes seconds) and
    /// "37 46.76" (degrees and decimal minutes).
    private static func degrees(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespaces)

        let pieces = cleaned.split(whereSeparator: { $0 == " " })
        guard !pieces.isEmpty, pieces.count <= 3 else { return nil }

        var values: [Double] = []
        for piece in pieces {
            guard let value = Double(piece) else { return nil }
            values.append(value)
        }

        // `-0 30` is half a degree south, and `values[0] < 0` is false for
        // minus zero: the sign bit is the only thing that still carries it.
        // The band matters - the equator and the Greenwich meridian.
        let negative = values[0].sign == .minus
        var total = abs(values[0])
        if values.count > 1 {
            guard values[1] >= 0, values[1] < 60 else { return nil }
            total += values[1] / 60
        }
        if values.count > 2 {
            guard values[2] >= 0, values[2] < 60 else { return nil }
            total += values[2] / 3600
        }
        return negative ? -total : total
    }

    private static func validated(latitude: Double, longitude: Double) -> Coordinate? {
        // A latitude out of bounds almost always betrays a longitude/latitude
        // paste in the wrong order. Fix it when the swap itself is valid.
        if abs(latitude) > 90, abs(longitude) <= 90 {
            let swapped = Coordinate(latitude: longitude, longitude: latitude)
            return swapped.isValid ? swapped : nil
        }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }
}
