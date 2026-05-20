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
}
