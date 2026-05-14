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
    var isRail: Bool { routeTypeSet.contains(2) || routeTypeSet.contains(1) }

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
    var isRail: Bool { routeTypeSet.contains(2) || routeTypeSet.contains(1) }

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
    let routeColor: String?
    let routeTextColor: String?
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
        case routeColor = "route_color"
        case routeTextColor = "route_text_color"
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

// MARK: - Journey planner

struct JourneyOption: Codable, Identifiable {
    let totalMinutes: Int
    let walkToMinutes: Int
    let transitMinutes: Int
    let walkFromMinutes: Int
    let route: JourneyRoute
    let tripId: String
    let headsign: String?
    let board: JourneyStopRef
    let alight: JourneyStopRef
    let isRealtime: Bool
    let delaySeconds: Int?

    var id: String { "\(tripId)|\(board.stopId)|\(alight.stopId)" }

    enum CodingKeys: String, CodingKey {
        case totalMinutes = "total_minutes"
        case walkToMinutes = "walk_to_minutes"
        case transitMinutes = "transit_minutes"
        case walkFromMinutes = "walk_from_minutes"
        case route
        case tripId = "trip_id"
        case headsign
        case board, alight
        case isRealtime = "is_realtime"
        case delaySeconds = "delay_seconds"
    }
}

struct JourneyRoute: Codable, Hashable {
    let routeId: String
    let routeShortName: String?
    let routeLongName: String?
    let routeType: Int
    let routeColor: String?
    let routeTextColor: String?

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

struct JourneyStopRef: Codable, Hashable {
    let stopId: String
    let stopName: String
    let stopLat: Double
    let stopLon: Double
    let walkDistanceM: Int
    let scheduledTime: Date
    let predictedTime: Date?

    var effectiveTime: Date { predictedTime ?? scheduledTime }

    enum CodingKeys: String, CodingKey {
        case stopId = "stop_id"
        case stopName = "stop_name"
        case stopLat = "stop_lat"
        case stopLon = "stop_lon"
        case walkDistanceM = "walk_distance_m"
        case scheduledTime = "scheduled_time"
        case predictedTime = "predicted_time"
    }
}

// MARK: - Route stops list

struct RouteStopsResponse: Codable {
    let routeShortName: String
    let routeLongName: String?
    let routeType: Int
    let routeColor: String?
    let routeTextColor: String?
    let directions: [RouteDirection]

    enum CodingKeys: String, CodingKey {
        case routeShortName = "route_short_name"
        case routeLongName = "route_long_name"
        case routeType = "route_type"
        case routeColor = "route_color"
        case routeTextColor = "route_text_color"
        case directions
    }
}

struct RouteDirection: Codable, Identifiable {
    let directionId: Int?
    let headsign: String?
    let stops: [RouteStop]

    var id: String { "\(directionId ?? -1)|\(headsign ?? "")" }

    enum CodingKeys: String, CodingKey {
        case directionId = "direction_id"
        case headsign
        case stops
    }
}

struct RouteStop: Codable, Identifiable {
    let stopId: String
    let stopCode: String?
    let stopName: String
    let stopLat: Double
    let stopLon: Double
    let locationType: Int
    let parentStation: String?
    let platformCode: String?
    let routeTypes: String?
    let stopSequence: Int

    var id: String { "\(stopId)@\(stopSequence)" }

    /// Convert to a `NearbyStop` so the existing `StopDetailView` can consume it.
    func asNearbyStop() -> NearbyStop {
        NearbyStop(
            stopId: stopId, stopCode: stopCode, stopName: stopName,
            stopLat: stopLat, stopLon: stopLon, locationType: locationType,
            parentStation: parentStation, platformCode: platformCode,
            routeTypes: routeTypes, distanceM: 0,
        )
    }

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
        case stopSequence = "stop_sequence"
    }
}

struct SchoolRouteMatch: Codable, Identifiable {
    let routeShortName: String
    let routeLongName: String?
    let routeType: Int
    let schoolHeadsign: String
    let nearestStop: NearbyStop

    var id: String { "\(routeShortName)|\(schoolHeadsign)" }

    enum CodingKeys: String, CodingKey {
        case routeShortName = "route_short_name"
        case routeLongName = "route_long_name"
        case routeType = "route_type"
        case schoolHeadsign = "school_headsign"
        case nearestStop = "nearest_stop"
    }
}

struct RouteNearestStop: Codable {
    let routeShortName: String
    let routeIds: [String]
    let nearestStop: NearbyStop

    enum CodingKeys: String, CodingKey {
        case routeShortName = "route_short_name"
        case routeIds = "route_ids"
        case nearestStop = "nearest_stop"
    }
}
