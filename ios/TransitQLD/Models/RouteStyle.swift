import SwiftUI

/// Canonical "how do we render this route" logic shared by Directions,
/// Pinned Journey, Stop Detail, Favourites, and Route Stops. Given a route's
/// GTFS fields (+ optional trip headsign), computes the display label,
/// background tint, foreground (text) colour, and SF Symbol icon.
///
/// Trains are special-cased throughout: they're grouped into named "lines"
/// (see `Models/TrainLine.swift`) with their own brand colours, and the
/// pill label prefers the trip headsign / line name over the raw GTFS
/// route_short_name.
enum RouteStyle {
    static func isTrain(_ routeType: Int) -> Bool {
        routeType == RouteType.rail.rawValue || routeType == RouteType.subway.rawValue
    }

    /// Pill / step label for a route. Trains get the destination / line
    /// name; other modes keep their existing short name (or long name /
    /// route id as a fallback).
    static func label(
        routeType: Int,
        routeShortName: String?,
        routeLongName: String?,
        routeColor: String?,
        headsign: String? = nil,
    ) -> String {
        if isTrain(routeType) {
            if let h = trainPillLabel(headsign: headsign) { return h }
            if let line = trainLine(longName: routeLongName, routeColor: routeColor) {
                return line.pillName
            }
        }
        return routeShortName ?? routeLongName ?? "?"
    }

    /// Background / icon tint for a route. Trains use the GTFS
    /// `route_color` (or the mapped line colour) so each line gets its
    /// official TransLink hue.
    static func tint(
        routeType: Int,
        routeColor: String?,
        routeLongName: String?,
        headsign: String? = nil,
    ) -> Color {
        if isTrain(routeType) {
            if let c = Color(gtfsHex: routeColor) { return c }
            if let line = trainLine(longName: routeLongName, routeColor: routeColor),
               let c = Color(gtfsHex: line.hex) { return c }
        }
        return defaultTint(routeType)
    }

    /// Foreground (text) colour for the pill — honours GTFS
    /// `route_text_color` when present so yellow Airport / Gold Coast pills
    /// get black text.
    static func foreground(routeType: Int, routeTextColor: String?) -> Color {
        if isTrain(routeType), let c = Color(gtfsHex: routeTextColor) { return c }
        return .white
    }

    static func icon(routeType: Int) -> String {
        switch RouteType(rawValue: routeType) {
        case .bus: return "bus.fill"
        case .rail, .subway: return "train.side.front.car"
        case .ferry: return "ferry.fill"
        case .tram: return "tram.fill"
        default: return "bus.fill"
        }
    }

    static func defaultTint(_ routeType: Int) -> Color {
        switch RouteType(rawValue: routeType) {
        case .bus: return .blue
        case .rail, .subway: return .indigo
        case .ferry: return NearbyStop.ferryTint
        case .tram: return .pink
        default: return .gray
        }
    }
}
