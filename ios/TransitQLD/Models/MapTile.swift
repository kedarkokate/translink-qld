import Foundation

/// One of the action pills that floats on the map. Fixed declaration order:
/// Home → Directions → Route. Their stack position on screen is configured
/// at runtime via `TilePosition`.
enum MapTileKind: String, Identifiable, CaseIterable, Codable {
    case home
    case directions
    case route
    case filters
    case favourites

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .directions: return "Directions"
        case .route: return "Route"
        case .filters: return "Filters"
        case .favourites: return "Favourites"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .directions: return "arrow.triangle.turn.up.right.diamond.fill"
        case .route: return "magnifyingglass"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .favourites: return "star.fill"
        }
    }

    /// When true the on-map pill renders the icon only (no text label).
    var iconOnlyOnMap: Bool {
        switch self {
        case .home: return true
        case .directions, .route, .filters, .favourites: return false
        }
    }
}

enum MapTileOrder {
    /// Default tile sequence on first launch.
    static let defaultOrder: [MapTileKind] = [.home, .directions, .route, .favourites, .filters]

    static let storageKey = "map_tile_order_v1"
    static let defaultRaw: String = defaultOrder.map(\.rawValue).joined(separator: ",")

    /// Decode a comma-separated raw string into a tile sequence, tolerant of
    /// missing or unknown entries: anything missing is appended in declaration
    /// order so new tiles auto-appear at the bottom for existing users.
    static func decode(_ raw: String) -> [MapTileKind] {
        let parsed = raw.split(separator: ",")
            .compactMap { MapTileKind(rawValue: String($0)) }
        var seen = Set<MapTileKind>()
        var ordered: [MapTileKind] = []
        for t in parsed where !seen.contains(t) {
            ordered.append(t); seen.insert(t)
        }
        for t in MapTileKind.allCases where !seen.contains(t) {
            ordered.append(t)
        }
        return ordered
    }

    static func encode(_ order: [MapTileKind]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}
