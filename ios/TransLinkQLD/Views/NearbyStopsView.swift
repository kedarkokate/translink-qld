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
    @State private var routeLookupShown = false
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
            mapView
                .navigationTitle("Nearby")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { refreshToolbar }
                .onChange(of: selectedStop) { _, new in
                    if new != nil { sheetShown = true }
                }
                .sheet(isPresented: $sheetShown, onDismiss: { selectedStop = nil }) {
                    stopDetailSheet
                }
                .sheet(isPresented: $routeLookupShown) {
                    RouteLookupView { stop, _ in focusOnRouteStop(stop) }
                        .presentationDetents([.medium, .large])
                }
        }
    }

    // MARK: Map

    private var mapView: some View {
        Map(position: $cameraPosition, selection: $selectedStop) {
            mapContent
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
        .overlay(alignment: .topLeading) {
            routePill
                .padding(.top, 10)
                .padding(.leading, 12)
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        UserAnnotation()
        ForEach(stops) { stop in
            marker(for: stop)
        }
    }

    private func marker(for stop: NearbyStop) -> some MapContent {
        Marker(stop.stopName,
               systemImage: stop.isFerry ? "ferry.fill" : "bus.fill",
               coordinate: stop.coordinate)
            .tint(stop.isFerry ? .blue : .red)
            .tag(stop)
    }

    // MARK: Overlays

    private var routePill: some View {
        Button {
            routeLookupShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Route").fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var refreshToolbar: some ToolbarContent {
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

    @ViewBuilder
    private var stopDetailSheet: some View {
        if let stop = selectedStop {
            StopDetailView(stop: stop)
                .presentationDetents([.fraction(0.45), .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Camera focus

    private func focusOnRouteStop(_ stop: NearbyStop) {
        let region: MKCoordinateRegion
        if let user = locationManager.lastLocation?.coordinate {
            region = regionFitting([user, stop.coordinate])
        } else {
            region = MKCoordinateRegion(
                center: stop.coordinate,
                latitudinalMeters: 500, longitudinalMeters: 500,
            )
        }
        withAnimation { cameraPosition = .region(region) }
    }

    private func regionFitting(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else { return Self.brisbaneFallback }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2,
        )
        // 1.6x padding keeps both endpoints comfortably inside the viewport;
        // 0.005° floor prevents a degenerate span when user and stop are close.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.005),
            longitudeDelta: max((maxLon - minLon) * 1.6, 0.005),
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: Nearby fetch

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
