import SwiftUI

// MARK: - Train line metadata
//
// TransLink's official network groups train routes into named "lines"
// (Airport, Beenleigh, Caboolture, …) each with a brand colour. GTFS encodes
// the colour per route in `route_color`, but the human-facing line name has
// to be derived from `route_long_name` ("Origin - Destination").
//
// For a stop pill we want:
//   - Background  → the GTFS route_color (authoritative).
//   - Label       → the line's terminus name, or the trip headsign when one
//                   is available.

struct TrainLine: Hashable {
    let name: String       // e.g. "Redcliffe Peninsula" — full official name
    let pillName: String   // e.g. "Redcliffe" — abbreviated to fit a pill
    let hex: String        // e.g. "1578BE"
}

private let lineByTerminus: [String: TrainLine] = [
    // Red family
    "Beenleigh":           TrainLine(name: "Beenleigh",           pillName: "Beenleigh",   hex: "E31837"),
    "Ferny Grove":         TrainLine(name: "Ferny Grove",         pillName: "Ferny Grove", hex: "E31837"),
    // Green family
    "Caboolture":          TrainLine(name: "Caboolture",          pillName: "Caboolture",  hex: "008752"),
    "Ipswich":             TrainLine(name: "Ipswich / Rosewood",  pillName: "Ipswich",     hex: "008752"),
    "Rosewood":            TrainLine(name: "Ipswich / Rosewood",  pillName: "Rosewood",    hex: "008752"),
    "Nambour":             TrainLine(name: "Sunshine Coast",      pillName: "Sunshine",    hex: "008752"),
    "Gympie North":        TrainLine(name: "Sunshine Coast",      pillName: "Sunshine",    hex: "008752"),
    // Light blue family
    "Redcliffe Peninsula": TrainLine(name: "Redcliffe Peninsula", pillName: "Redcliffe",   hex: "1578BE"),
    "Kippa-Ring":          TrainLine(name: "Redcliffe Peninsula", pillName: "Redcliffe",   hex: "1578BE"),
    "Springfield":         TrainLine(name: "Springfield",         pillName: "Springfield", hex: "1578BE"),
    "Springfield Central": TrainLine(name: "Springfield",         pillName: "Springfield", hex: "1578BE"),
    // Navy family
    "Cleveland":           TrainLine(name: "Cleveland",           pillName: "Cleveland",   hex: "00467F"),
    "Manly":               TrainLine(name: "Cleveland",           pillName: "Cleveland",   hex: "00467F"),
    "Shorncliffe":         TrainLine(name: "Shorncliffe",         pillName: "Shorncliffe", hex: "00447C"),
    "Sandgate":            TrainLine(name: "Shorncliffe",         pillName: "Shorncliffe", hex: "00447C"),
    // Yellow family
    "Airport":             TrainLine(name: "Airport",             pillName: "Airport",     hex: "FFC425"),
    "Domestic":            TrainLine(name: "Airport",             pillName: "Airport",     hex: "FFC425"),
    "Domestic Airport":    TrainLine(name: "Airport",             pillName: "Airport",     hex: "FFC425"),
    "International":       TrainLine(name: "Airport",             pillName: "Airport",     hex: "FFC425"),
    "Varsity Lakes":       TrainLine(name: "Gold Coast",          pillName: "Gold Coast",  hex: "FFC425"),
    "Helensvale":          TrainLine(name: "Gold Coast",          pillName: "Gold Coast",  hex: "FFC425"),
    "Robina":              TrainLine(name: "Gold Coast",          pillName: "Gold Coast",  hex: "FFC425"),
    "Coomera":             TrainLine(name: "Gold Coast",          pillName: "Gold Coast",  hex: "FFC425"),
    // Purple
    "Doomben":             TrainLine(name: "Doomben",             pillName: "Doomben",     hex: "A54399"),
]

/// The City Loop service (route_short_name "BRBR") circles Bowen Hills →
/// Fortitude Valley → Central → Roma Street → South Brisbane → South Bank →
/// Boggo Road (and the reverse). TransLink's GTFS gives it route_color
/// A0A0A0 — a flat "no brand" grey — so we give it its own distinct colour
/// here rather than show a washed-out pill.
private let cityLoopLine = TrainLine(name: "City Loop", pillName: "City Loop", hex: "006D77")

/// Parse a GTFS `route_long_name` of the form "Origin - Destination" and pick
/// the outer terminus that names the line. When both ends are non–Brisbane
/// City (through-routes like "Ipswich - Redcliffe Peninsula"), the route's
/// own GTFS colour is used to disambiguate.
func trainLine(longName: String?, routeColor: String?) -> TrainLine? {
    guard let longName else { return nil }
    let parts = longName.components(separatedBy: " - ").map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    if parts.count == 2, parts[0] == "Brisbane City", parts[1] == "Brisbane City" {
        return cityLoopLine
    }
    let endpoints = parts.compactMap { lineByTerminus[$0] }

    if endpoints.count == 1 { return endpoints[0] }
    if endpoints.count >= 2, let color = routeColor?.uppercased(), !color.isEmpty {
        if let match = endpoints.first(where: { $0.hex.caseInsensitiveCompare(color) == .orderedSame }) {
            return match
        }
    }
    // Through-route within the same colour family or unmapped — caller falls
    // back to displayName / route_long_name as needed.
    return endpoints.first
}

/// Pill label for a train trip whose headsign is known (e.g. "Beenleigh
/// station" → "Beenleigh"). Returns nil if no useful headsign is present.
func trainPillLabel(headsign: String?) -> String? {
    guard let raw = headsign?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    let stripped = raw
        .replacingOccurrences(of: " station", with: "", options: .caseInsensitive)
        .replacingOccurrences(of: " Station", with: "")
    if let line = lineByTerminus[stripped] {
        return line.pillName
    }
    return stripped
}

// MARK: - Hex → Color

extension Color {
    /// "1578BE" / "#1578BE" → SwiftUI.Color, or nil if the string isn't a
    /// 6-digit hex value.
    init?(gtfsHex: String?) {
        guard var hex = gtfsHex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >>  8) & 0xFF) / 255.0
        let b = Double( v        & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
