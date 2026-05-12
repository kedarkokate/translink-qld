import SwiftUI
import MapKit
import CoreLocation

struct NearbyStopsView: View {
    @Environment(LocationManager.self) private var locationManager
    @State private var stops: [NearbyStop] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedStop: NearbyStop?
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
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition, selection: $selectedStop) {
                    UserAnnotation()
                    ForEach(stops) { stop in
                        Marker(stop.stopName, systemImage: "bus.fill",
                               coordinate: stop.coordinate)
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

                stopsCard
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        scheduleReload(delayMs: 0)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $selectedStop) { stop in
                StopDetailView(stopId: stop.stopId, stopName: stop.stopName)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var stopsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stops in view").font(.headline)
                Spacer()
                if loading { ProgressView().scaleEffect(0.8) }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if stops.isEmpty && !loading {
                Text("No stops in this area. Try panning or zooming in.")
                    .foregroundStyle(.secondary).font(.subheadline)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(stops) { stop in
                            Button {
                                selectedStop = stop
                            } label: {
                                stopChip(stop)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func stopChip(_ stop: NearbyStop) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stop.stopName).font(.subheadline).lineLimit(1)
            Text("\(Int(stop.distanceM)) m").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
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
        // Convert the visible span to meters so we ask the API for stops
        // covering roughly the visible viewport.
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
