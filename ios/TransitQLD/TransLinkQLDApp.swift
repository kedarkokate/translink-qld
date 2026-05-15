import SwiftUI

@main
struct TransLinkQLDApp: App {
    @State private var locationManager = LocationManager()
    @State private var favourites = FavouritesStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(locationManager)
                .environment(favourites)
        }
    }
}
