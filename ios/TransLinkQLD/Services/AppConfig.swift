import Foundation

enum AppConfig {
    /// Set this to your deployed Worker URL once you run `wrangler deploy`.
    /// For local dev you can point this at the wrangler dev server
    /// (default: http://localhost:8787) — note that the iOS simulator can
    /// reach localhost directly; a physical device needs your Mac's LAN IP.
    static let apiBaseURL: URL = URL(string: "http://localhost:8787")!
}
