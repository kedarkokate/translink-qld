import SwiftUI

struct RootView: View {
    @Environment(LocationManager.self) private var locationManager

    var body: some View {
        NearbyStopsView()
            .task {
                locationManager.start()
            }
    }
}
