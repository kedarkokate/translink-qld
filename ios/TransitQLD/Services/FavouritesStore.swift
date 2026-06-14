import Foundation
import Observation

/// Single source of truth for the user's favourited stops and services.
/// Persists Codable JSON in UserDefaults — small enough to be cheap, and
/// avoids the ceremony of SwiftData for ~tens of records.
@Observable
final class FavouritesStore {
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

    /// Toggle a favourite service on/off: removes the existing matching
    /// favourite (same stop + route + headsign + time-of-day) if one
    /// exists, otherwise adds `service`.
    func toggleService(_ service: FavouriteService) {
        if let existing = self.service(
            matching: service.stopId, route: service.routeShortName,
            headsign: service.headsign, secondsSinceMidnight: service.scheduledSecondsSinceMidnight,
        ) {
            removeService(id: existing.id)
        } else {
            addService(service)
        }
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
            migrateDroppingTimeSpecific()
        }
    }

    /// v1.0 dropped the time-specific service favourite (the "07:42 only"
    /// option). For users upgrading from a build that exposed it, coerce
    /// any saved time-specific entries to the broader "any time" form and
    /// dedupe against the route-at-stop entry they may already have. Runs
    /// once on load; idempotent (no work + no save if already normalised).
    private func migrateDroppingTimeSpecific() {
        var changed = false
        var byKey: [String: FavouriteService] = [:]
        for svc in services {
            let normalised: FavouriteService
            if svc.scheduledSecondsSinceMidnight != nil {
                changed = true
                normalised = FavouriteService(
                    id: svc.id,
                    stopId: svc.stopId, stopName: svc.stopName, stopCode: svc.stopCode,
                    stopLat: svc.stopLat, stopLon: svc.stopLon, routeTypes: svc.routeTypes,
                    routeShortName: svc.routeShortName, routeLongName: svc.routeLongName,
                    routeType: svc.routeType,
                    routeColor: svc.routeColor, routeTextColor: svc.routeTextColor,
                    headsign: svc.headsign, scheduledSecondsSinceMidnight: nil,
                    addedAt: svc.addedAt,
                )
            } else {
                normalised = svc
            }
            // Keep the earliest-added entry per matchKey; later duplicates
            // are dropped on the assumption the user added the broader one
            // first and the time-specific one second.
            if let existing = byKey[normalised.matchKey] {
                changed = true
                if normalised.addedAt < existing.addedAt {
                    byKey[normalised.matchKey] = normalised
                }
            } else {
                byKey[normalised.matchKey] = normalised
            }
        }
        if changed {
            services = Array(byKey.values).sorted { $0.addedAt < $1.addedAt }
            save()
        }
    }
}
