import Foundation
import CoreLocation

/// A place the user can pick as the start or end of a journey. Unifies our
/// own stops, Apple-resolved addresses/POIs, and the live user location into
/// a single value type the UI deals with.
struct SearchLocation: Identifiable, Hashable {
    enum Kind: Hashable {
        case currentLocation
        case stop(stopId: String, routeTypes: String?)
        case place
    }

    let id: String
    let title: String
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D
    let kind: Kind

    static func currentLocation(_ coord: CLLocationCoordinate2D) -> SearchLocation {
        SearchLocation(
            id: "current",
            title: "Current Location",
            subtitle: nil,
            coordinate: coord,
            kind: .currentLocation,
        )
    }

    static func from(stop: NearbyStop) -> SearchLocation {
        SearchLocation(
            id: "stop:\(stop.stopId)",
            title: stop.stopName,
            subtitle: stop.stopCode.map { "Stop \($0)" },
            coordinate: stop.coordinate,
            kind: .stop(stopId: stop.stopId, routeTypes: stop.routeTypes),
        )
    }

    var symbolName: String {
        switch kind {
        case .currentLocation:
            return "location.fill"
        case .stop(_, let routeTypes):
            let types = parseRouteTypes(routeTypes)
            if types.contains(4) { return "ferry.fill" }
            if types.contains(2) { return "train.side.front.car" }
            return "bus.fill"
        case .place:
            return "mappin.circle.fill"
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: SearchLocation, b: SearchLocation) -> Bool { a.id == b.id }
}
