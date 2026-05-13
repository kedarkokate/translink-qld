import Foundation

/// One of the action pills that floats on the map. Fixed declaration order:
/// Home → Directions → Route. Their stack position on screen is configured
/// at runtime via `TilePosition`.
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

    /// When true the on-map pill renders the icon only (no text label).
    var iconOnlyOnMap: Bool {
        switch self {
        case .home: return true
        case .directions, .route: return false
        }
    }
}
