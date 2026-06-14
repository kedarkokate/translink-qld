import Foundation

// MARK: - Favourite stop
//
// A bookmark for a stop. Carries enough cached fields to render a list row
// and re-open the stop detail sheet without re-fetching the stop record.

struct FavouriteStop: Codable, Identifiable, Hashable {
    let id: UUID
    let stopId: String
    let stopName: String
    let stopCode: String?
    let routeTypes: String?
    let lat: Double
    let lon: Double
    let addedAt: Date

    init(
        id: UUID = UUID(),
        stopId: String, stopName: String, stopCode: String?,
        routeTypes: String?, lat: Double, lon: Double,
        addedAt: Date = Date(),
    ) {
        self.id = id
        self.stopId = stopId
        self.stopName = stopName
        self.stopCode = stopCode
        self.routeTypes = routeTypes
        self.lat = lat
        self.lon = lon
        self.addedAt = addedAt
    }

    /// Rehydrate a `NearbyStop` so the favourite can be opened with the
    /// existing `StopDetailView` flow. `distanceM` is set to 0 since
    /// favourites aren't tied to the user's current location.
    func asNearbyStop() -> NearbyStop {
        NearbyStop(
            stopId: stopId, stopCode: stopCode, stopName: stopName,
            lat: lat, lon: lon, routeTypes: routeTypes, distanceM: 0,
        )
    }
}

// MARK: - Favourite service
//
// A bookmark for a particular scheduled departure at a stop: route +
// direction + time-of-day. Cached colour / name fields so the list row
// renders correctly without another network call.

struct FavouriteService: Codable, Identifiable, Hashable {
    let id: UUID

    // Stop context.
    let stopId: String
    let stopName: String
    let stopCode: String?
    let stopLat: Double
    let stopLon: Double
    let routeTypes: String?

    // Route context.
    let routeShortName: String
    let routeLongName: String?
    let routeType: Int
    let routeColor: String?
    let routeTextColor: String?

    // Trip identity.
    let headsign: String?
    /// Brisbane-local seconds since midnight (e.g. 07:42 → 27720). `nil`
    /// means "any departure of this route+direction at this stop" — i.e.
    /// the broader route-at-stop favourite. A specific Int pins it to a
    /// single scheduled time.
    let scheduledSecondsSinceMidnight: Int?

    let addedAt: Date

    init(
        id: UUID = UUID(),
        stopId: String, stopName: String, stopCode: String?,
        stopLat: Double, stopLon: Double, routeTypes: String?,
        routeShortName: String, routeLongName: String?,
        routeType: Int, routeColor: String?, routeTextColor: String?,
        headsign: String?, scheduledSecondsSinceMidnight: Int?,
        addedAt: Date = Date(),
    ) {
        self.id = id
        self.stopId = stopId
        self.stopName = stopName
        self.stopCode = stopCode
        self.stopLat = stopLat
        self.stopLon = stopLon
        self.routeTypes = routeTypes
        self.routeShortName = routeShortName
        self.routeLongName = routeLongName
        self.routeType = routeType
        self.routeColor = routeColor
        self.routeTextColor = routeTextColor
        self.headsign = headsign
        self.scheduledSecondsSinceMidnight = scheduledSecondsSinceMidnight
        self.addedAt = addedAt
    }

    func asNearbyStop() -> NearbyStop {
        NearbyStop(
            stopId: stopId, stopCode: stopCode, stopName: stopName,
            lat: stopLat, lon: stopLon, routeTypes: routeTypes, distanceM: 0,
        )
    }

    /// "07:42 AM" — Brisbane-local time-of-day, formatted for the UI.
    /// Returns nil for route-at-stop favourites (where the time is unset).
    var timeLabel: String? {
        guard let total = scheduledSecondsSinceMidnight, total >= 0 else { return nil }
        let h = (total / 3600) % 24
        let m = (total / 60) % 60
        let comps = DateComponents(hour: h, minute: m)
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.timeOfDay
    }

    /// True when this favourite is time-specific (a particular scheduled
    /// run, e.g. the 07:42), false when it's a broader route-at-stop bookmark.
    var isTimeSpecific: Bool { scheduledSecondsSinceMidnight != nil }

    /// Identity used to detect duplicates and power "is this row favourited?"
    /// checks. Two services are the same when they share stop + route +
    /// direction + (scheduled time-of-day OR "any").
    var matchKey: String {
        let time = scheduledSecondsSinceMidnight.map(String.init) ?? "any"
        return "\(stopId)|\(routeShortName)|\(headsign ?? "")|\(time)"
    }
}

extension Departure {
    /// Brisbane-local seconds since midnight for this scheduled departure.
    /// Used as the canonical time-of-day key when adding a favourite.
    var brisbaneSecondsSinceMidnight: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? cal.timeZone
        let parts = cal.dateComponents([.hour, .minute, .second], from: scheduledDeparture)
        return (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
    }
}
