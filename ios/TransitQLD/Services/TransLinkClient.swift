import Foundation
import CoreLocation

enum TransLinkError: Error, LocalizedError {
    case badURL
    case http(Int)
    case decode(Error)

    var errorDescription: String? {
        switch self {
        case .badURL: "Bad request URL"
        case .http(let c): "Server returned HTTP \(c)"
        case .decode(let e): "Decode error: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class TransLinkClient {
    static let shared = TransLinkClient()

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL = AppConfig.apiBaseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        let d = JSONDecoder()
        // The API returns ISO-8601 dates with fractional seconds
        // (e.g. "2026-08-15T23:08:00.000Z" from JS Date.toISOString()).
        // Swift's built-in .iso8601 strategy can't handle fractional seconds.
        // ISO8601DateFormatter is not a DateFormatter subclass so .formatted()
        // won't accept it — use .custom instead.
        nonisolated(unsafe) let isoMs = ISO8601DateFormatter()
        isoMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        nonisolated(unsafe) let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = isoMs.date(from: s)    { return date }
            if let date = isoPlain.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Cannot decode date string: \(s)"
            )
        }
        self.decoder = d
    }

    func nearbyStops(
        lat: Double, lon: Double,
        radiusM: Int = 500, limit: Int = 25,
    ) async throws -> [NearbyStop] {
        struct Resp: Decodable { let stops: [NearbyStop] }
        let url = try makeURL("/v1/stops/nearby", query: [
            "lat": "\(lat)", "lon": "\(lon)",
            "radius_m": "\(radiusM)", "limit": "\(limit)",
        ])
        return try await get(url, as: Resp.self).stops
    }

    func stopDetail(stopId: String) async throws -> StopDetail {
        let url = try makeURL("/v1/stops/\(stopId)")
        return try await get(url, as: StopDetail.self)
    }

    func departures(
        stopId: String, limit: Int = 15, windowMin: Int = 60,
    ) async throws -> [Departure] {
        struct Resp: Decodable { let departures: [Departure] }
        let url = try makeURL("/v1/stops/\(stopId)/departures", query: [
            "limit": "\(limit)", "window_min": "\(windowMin)",
        ])
        return try await get(url, as: Resp.self).departures
    }

    func schoolRoutesNear(
        lat: Double, lon: Double, radiusM: Int, limit: Int = 25,
    ) async throws -> [SchoolRouteMatch] {
        struct Resp: Decodable { let matches: [SchoolRouteMatch] }
        let url = try makeURL("/v1/routes/schools", query: [
            "lat": "\(lat)", "lon": "\(lon)",
            "radius_m": "\(radiusM)", "limit": "\(limit)",
        ])
        return try await get(url, as: Resp.self).matches
    }

    func routeStops(shortName: String) async throws -> RouteStopsResponse {
        let url = try makeURL("/v1/routes/\(shortName)/stops")
        return try await get(url, as: RouteStopsResponse.self)
    }

    func planJourney(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        windowMin: Int = 90,
        walkToM: Int = 500,
        walkFromM: Int = 500,
        limit: Int = 12,
    ) async throws -> [JourneyOption] {
        struct Resp: Decodable { let options: [JourneyOption] }
        let url = try makeURL("/v1/journey", query: [
            "from_lat": "\(from.latitude)", "from_lon": "\(from.longitude)",
            "to_lat":   "\(to.latitude)",   "to_lon":   "\(to.longitude)",
            "window_min": "\(windowMin)",
            "walk_to_m":   "\(walkToM)",
            "walk_from_m": "\(walkFromM)",
            "limit": "\(limit)",
            // 1.0.1+ opts into hub-anchored one-transfer journeys. The
            // backend defaults to direct-only when this flag is absent,
            // so 1.0.0 clients keep getting the original behaviour.
            "transfers": "1",
        ])
        return try await get(url, as: Resp.self).options
    }

    func searchStops(
        query: String, near: CLLocationCoordinate2D? = nil, limit: Int = 10,
    ) async throws -> [NearbyStop] {
        struct Resp: Decodable { let stops: [NearbyStop] }
        var q: [String: String] = ["q": query, "limit": "\(limit)"]
        if let near {
            q["lat"] = "\(near.latitude)"
            q["lon"] = "\(near.longitude)"
        }
        let url = try makeURL("/v1/stops/search", query: q)
        return try await get(url, as: Resp.self).stops
    }

    func routeNearestStop(
        shortName: String, lat: Double, lon: Double,
    ) async throws -> RouteNearestStop {
        let url = try makeURL("/v1/routes/\(shortName)/nearest-stop", query: [
            "lat": "\(lat)", "lon": "\(lon)",
        ])
        return try await get(url, as: RouteNearestStop.self)
    }

    private func get<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse else { throw TransLinkError.http(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw TransLinkError.http(http.statusCode)
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw TransLinkError.decode(error) }
    }

    private func makeURL(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false,
        ) else { throw TransLinkError.badURL }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw TransLinkError.badURL }
        return url
    }
}
