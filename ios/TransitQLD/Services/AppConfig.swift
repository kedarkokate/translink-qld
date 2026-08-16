import Foundation

enum AppConfig {
    /// Debug builds (Simulator, local dev) hit the local `wrangler dev`
    /// server. Release builds hit the deployed production Worker.
    static let apiBaseURL: URL = {
        #if DEBUG
        return URL(string: "http://localhost:8787")!
        #else
        return URL(string: "https://translink-qld.transitqld.workers.dev")!
        #endif
    }()

    /// App Store listing, used by the Settings "Share" action.
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/transitqld/id6769756778")!

    // MARK: Journey planner walk-distance preferences
    /// AppStorage key for max walking distance to the boarding stop (metres).
    static let walkToMKey   = "journey_walk_to_m_v1"
    /// AppStorage key for max walking distance from the alighting stop (metres).
    static let walkFromMKey = "journey_walk_from_m_v1"
    /// Default walk radius used on both legs when no preference is stored.
    static let defaultWalkM = 800
}
