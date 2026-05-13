import SwiftUI

@main
struct TransLinkQLDApp: App {
    @State private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(locationManager)
        }
    }
}
