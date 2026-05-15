import Foundation
import Observation

/// Single source of truth for the user's favourited stops and services.
/// Persists Codable JSON in UserDefaults — small enough to be cheap, and
/// avoids the ceremony of SwiftData for ~tens of records.
@Observable
final class FavouritesStore {
    static let shared = FavouritesStore()

    private(set) var stops: [FavouriteStop] = []
    private(set) var services: [FavouriteService] = []

    private static let stopsKey = "favourites.stops.v1"
    private static let servicesKey = "favourites.services.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    // MARK: - Stops

    func isStopFavourite(stopId: String) -> Bool {
        stops.contains { $0.stopId == stopId }
    }

    func addStop(_ stop: FavouriteStop) {
        guard !isStopFavourite(stopId: stop.stopId) else { return }
        stops.append(stop)
        save()
    }

    func removeStop(stopId: String) {
        stops.removeAll { $0.stopId == stopId }
        save()
    }

    func removeStop(id: UUID) {
        stops.removeAll { $0.id == id }
        save()
    }

    // MARK: - Services

    /// Find a favourite that matches a specific (stop, route, headsign, time).
    /// Pass `nil` for `secondsSinceMidnight` to match the broader
    /// route-at-stop favourite (one without a time component). Time-specific
    /// matches tolerate a ±60 s drift in the cached value.
    func service(matching stopId: String, route: String, headsign: String?, secondsSinceMidnight: Int?) -> FavouriteService? {
        services.first { svc in
            guard svc.stopId == stopId,
                  svc.routeShortName == route,
                  (svc.headsign ?? "") == (headsign ?? "") else { return false }
            switch (svc.scheduledSecondsSinceMidnight, secondsSinceMidnight) {
            case (nil, nil): return true
            case let (a?, b?): return abs(a - b) <= 60
            default: return false
            }
        }
    }

    func isServiceFavourite(stopId: String, route: String, headsign: String?, secondsSinceMidnight: Int?) -> Bool {
        service(matching: stopId, route: route, headsign: headsign,
                secondsSinceMidnight: secondsSinceMidnight) != nil
    }

    func addService(_ service: FavouriteService) {
        // Avoid duplicates if the user taps quickly.
        guard !isServiceFavourite(
            stopId: service.stopId, route: service.routeShortName,
            headsign: service.headsign,
            secondsSinceMidnight: service.scheduledSecondsSinceMidnight,
        ) else { return }
        services.append(service)
        save()
    }

    func updateService(_ updated: FavouriteService) {
        guard let idx = services.firstIndex(where: { $0.id == updated.id }) else { return }
        services[idx] = updated
        save()
    }

    func removeService(id: UUID) {
        services.removeAll { $0.id == id }
        save()
    }

    // MARK: - Computed

    var hasAnyFavourites: Bool { !stops.isEmpty || !services.isEmpty }

    // MARK: - Persistence

    private func save() {
        if let data = try? encoder.encode(stops) {
            defaults.set(data, forKey: Self.stopsKey)
        }
        if let data = try? encoder.encode(services) {
            defaults.set(data, forKey: Self.servicesKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: Self.stopsKey),
           let decoded = try? decoder.decode([FavouriteStop].self, from: data) {
            stops = decoded
        }
        if let data = defaults.data(forKey: Self.servicesKey),
           let decoded = try? decoder.decode([FavouriteService].self, from: data) {
            services = decoded
        }
    }
}
