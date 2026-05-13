import SwiftUI
import MapKit
import CoreLocation

struct NearbyStopsView: View {
    @Environment(LocationManager.self) private var locationManager
    @State private var stops: [NearbyStop] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedStop: NearbyStop?
    @State private var sheetShown = false
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var fetchTask: Task<Void, Never>?
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        followsHeading: false, fallback: .region(brisbaneFallback)
    )

    static let brisbaneFallback = MKCoordinateRegion(
        center: .init(latitude: -27.4698, longitude: 153.0251),
        latitudinalMeters: 1500, longitudinalMeters: 1500,
    )

    private static let minRadiusM: Double = 150
    private static let maxRadiusM: Double = 3000

    var body: some View {
        NavigationStack {
            Map(position: $cameraPosition, selection: $selectedStop) {
                UserAnnotation()
                ForEach(stops) { stop in
                    Marker(stop.stopName,
                           systemImage: stop.isFerry ? "ferry.fill" : "bus.fill",
                           coordinate: stop.coordinate)
                        .tint(stop.isFerry ? .blue : .red)
                        .tag(stop)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                scheduleReload()
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        scheduleReload(delayMs: 0)
                    } label: {
                        if loading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(loading)
                }
            }
            .onChange(of: selectedStop) { _, newStop in
                if newStop != nil { sheetShown = true }
            }
            .sheet(isPresented: $sheetShown, onDismiss: {
                selectedStop = nil
            }) {
                if let stop = selectedStop {
                    StopDetailView(stop: stop)
                        .presentationDetents([.fraction(0.45), .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    private func scheduleReload(delayMs: Int = 250) {
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
            }
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        guard let region = visibleRegion else { return }
        let center = region.center
        let latMeters = region.span.latitudeDelta * 111_000
        let lonMeters = region.span.longitudeDelta * 111_000
            * cos(center.latitude * .pi / 180)
        let raw = max(latMeters, lonMeters) / 2
        let radius = min(max(raw, Self.minRadiusM), Self.maxRadiusM)

        loading = true; error = nil
        defer { loading = false }
        do {
            stops = try await TransLinkClient.shared.nearbyStops(
                lat: center.latitude,
                lon: center.longitude,
                radiusM: Int(radius), limit: 100,
            )
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
