import Foundation
import CoreLocation

struct Stop: Codable, Identifiable, Hashable {
    let stopId: String
    let stopCode: String?
    let stopName: String
    let stopLat: Double
    let stopLon: Double
    let locationType: Int
    let parentStation: String?
    let platformCode: String?
    let routeTypes: String?

    var id: String { stopId }
    var coordinate: CLLocationCoordinate2D {
        .init(latitude: stopLat, longitude: stopLon)
    }
    var routeTypeSet: Set<Int> { parseRouteTypes(routeTypes) }
    var isFerry: Bool { routeTypeSet.contains(4) }

    enum CodingKeys: String, CodingKey {
        case stopId = "stop_id"
        case stopCode = "stop_code"
        case stopName = "stop_name"
        case stopLat = "stop_lat"
        case stopLon = "stop_lon"
        case locationType = "location_type"
        case parentStation = "parent_station"
        case platformCode = "platform_code"
        case routeTypes = "route_types"
    }
}

struct NearbyStop: Codable, Identifiable, Hashable {
    let stopId: String
    let stopCode: String?
    let stopName: String
    let stopLat: Double
    let stopLon: Double
    let locationType: Int
    let parentStation: String?
    let platformCode: String?
    let routeTypes: String?
    let distanceM: Double

    var id: String { stopId }
    var coordinate: CLLocationCoordinate2D {
        .init(latitude: stopLat, longitude: stopLon)
    }
    var routeTypeSet: Set<Int> { parseRouteTypes(routeTypes) }
    var isFerry: Bool { routeTypeSet.contains(4) }

    enum CodingKeys: String, CodingKey {
        case stopId = "stop_id"
        case stopCode = "stop_code"
        case stopName = "stop_name"
        case stopLat = "stop_lat"
        case stopLon = "stop_lon"
        case locationType = "location_type"
        case parentStation = "parent_station"
        case platformCode = "platform_code"
        case routeTypes = "route_types"
        case distanceM = "distance_m"
    }
}

private func parseRouteTypes(_ raw: String?) -> Set<Int> {
    guard let raw, !raw.isEmpty else { return [] }
    return Set(raw.split(separator: ",").compactMap {
        Int($0.trimmingCharacters(in: .whitespaces))
    })
}

struct Route: Codable, Identifiable, Hashable {
    let routeId: String
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int
    let routeColor: String?
    let routeTextColor: String?

    var id: String { routeId }
    var displayName: String { routeShortName ?? routeLongName ?? routeId }

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case routeShortName = "route_short_name"
        case routeLongName = "route_long_name"
        case routeType = "route_type"
        case routeColor = "route_color"
        case routeTextColor = "route_text_color"
    }
}

enum RouteType: Int {
    case tram = 0
    case subway = 1
    case rail = 2
    case bus = 3
    case ferry = 4

    var symbolName: String {
        switch self {
        case .tram: "tram.fill"
        case .subway, .rail: "train.side.front.car"
        case .bus: "bus.fill"
        case .ferry: "ferry.fill"
        }
    }
}

struct Departure: Codable, Identifiable, Hashable {
    let tripId: String
    let routeId: String
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int
    let headsign: String?
    let scheduledDeparture: Date
    let predictedDeparture: Date?
    let delaySeconds: Int?
    let isRealtime: Bool
    let isCancelled: Bool

    var id: String { tripId + scheduledDeparture.ISO8601Format() }
    var effectiveDeparture: Date { predictedDeparture ?? scheduledDeparture }
    var routeBadge: String { routeShortName ?? routeId }

    enum CodingKeys: String, CodingKey {
        case tripId = "trip_id"
        case routeId = "route_id"
        case routeShortName = "route_short_name"
        case routeLongName = "route_long_name"
        case routeType = "route_type"
        case headsign
        case scheduledDeparture = "scheduled_departure"
        case predictedDeparture = "predicted_departure"
        case delaySeconds = "delay_seconds"
        case isRealtime = "is_realtime"
        case isCancelled = "is_cancelled"
    }
}

struct VehiclePosition: Codable, Identifiable, Hashable {
    let vehicleId: String
    let tripId: String?
    let routeId: String?
    let lat: Double
    let lon: Double
    let bearing: Double?
    let speed: Double?
    let timestamp: Int

    var id: String { vehicleId }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    enum CodingKeys: String, CodingKey {
        case vehicleId = "vehicle_id"
        case tripId = "trip_id"
        case routeId = "route_id"
        case lat, lon, bearing, speed, timestamp
    }
}

struct StopDetail: Codable {
    let stop: Stop
    let routes: [Route]
}
