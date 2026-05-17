import SwiftUI

struct RootView: View {
    @Environment(LocationManager.self) private var locationManager
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        NearbyStopsView()
            .task {
                locationManager.start()
            }
            .preferredColorScheme(appearance.colorScheme)
    }
}
