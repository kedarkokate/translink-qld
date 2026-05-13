import Foundation

/// One of the action pills that floats on the top-left of the map. Their
/// on-screen order is user-configurable; the order is persisted via
/// `@AppStorage` and rendered by `NearbyStopsView`.
enum MapTileKind: String, Identifiable, CaseIterable, Codable {
    case home
    case directions
    case route

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .directions: return "Directions"
        case .route: return "Route"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .directions: return "arrow.triangle.turn.up.right.diamond.fill"
        case .route: return "magnifyingglass"
        }
    }

    /// When true the on-map pill renders the icon only (no text). Other
    /// surfaces (e.g. the customize sheet) still show the label so users
    /// know what the icon means.
    var iconOnlyOnMap: Bool {
        switch self {
        case .home: return true
        case .directions, .route: return false
        }
    }
}

enum MapTileOrder {
    /// Default first-launch order: Home → Directions → Route.
    static let defaultOrder: [MapTileKind] = [.home, .directions, .route]

    static let storageKey = "map_tile_order_v1"
    static let defaultRaw: String = defaultOrder.map(\.rawValue).joined(separator: ",")

    static func decode(_ raw: String) -> [MapTileKind] {
        let parsed = raw.split(separator: ",")
            .compactMap { MapTileKind(rawValue: String($0)) }
        // Always ensure every tile kind is represented exactly once, so a
        // future code change that adds a new tile auto-appears at the end
        // for existing users.
        var seen = Set<MapTileKind>()
        var ordered = [MapTileKind]()
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
