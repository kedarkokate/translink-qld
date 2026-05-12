import Foundation

enum AppConfig {
    /// Production Cloudflare Worker. For local development against
    /// `wrangler dev`, set the LOCAL_BACKEND env var when building, or
    /// flip the literal below to `http://localhost:8787`.
    static let apiBaseURL: URL = URL(
        string: "https://translink-qld.kedarkokate.workers.dev",
    )!
}
