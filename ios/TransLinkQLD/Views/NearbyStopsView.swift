import SwiftUI
import MapKit
import CoreLocation

struct NearbyStopsView: View {
    @Environment(LocationManager.self) private var locationManager
    @State private var stops: [NearbyStop] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedStop: NearbyStop?
    @State private var detailStop: NearbyStop?
    @State private var nextDeparture: Departure?
    @State private var loadingNextDeparture = false
    @State private var nextDepartureError: String?
    @State private var nextDepartureTask: Task<Void, Never>?
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

                bottomCard
                    .animation(.spring(duration: 0.3), value: selectedStop)
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
            .onChange(of: selectedStop) { _, newStop in
                handleSelectionChange(newStop)
            }
            .sheet(item: $detailStop) { stop in
                StopDetailView(stopId: stop.stopId, stopName: stop.stopName)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var bottomCard: some View {
        if let stop = selectedStop {
            selectedStopCard(stop)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            stopsCard
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private func selectedStopCard(_ stop: NearbyStop) -> some View {
        Button {
            detailStop = stop
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.stopName).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                        if let code = stop.stopCode {
                            Text("Stop \(code)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        selectedStop = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                nextDepartureRow
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var nextDepartureRow: some View {
        if loadingNextDeparture && nextDeparture == nil {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Loading next departure…").font(.subheadline).foregroundStyle(.secondary)
            }
        } else if let err = nextDepartureError {
            Text(err).font(.caption).foregroundStyle(.red)
        } else if let dep = nextDeparture {
            HStack(spacing: 12) {
                routeBadge(dep)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dep.headsign ?? dep.routeLongName ?? "—")
                        .font(.subheadline).lineLimit(1)
                    if dep.isRealtime {
                        HStack(spacing: 3) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("Live")
                        }.font(.caption2).foregroundStyle(.green)
                    } else {
                        Text("Scheduled").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                departureTimeView(dep)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(dep.isCancelled ? 0.4 : 1)
        } else {
            Text("No upcoming departures in the next 3 hours.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func routeBadge(_ dep: Departure) -> some View {
        let color: Color = switch RouteType(rawValue: dep.routeType) {
        case .bus: .blue
        case .rail, .subway: .yellow
        case .ferry: .cyan
        case .tram: .pink
        default: .gray
        }
        return Text(dep.routeBadge)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 48)
    }

    private func departureTimeView(_ dep: Departure) -> some View {
        let target = dep.effectiveDeparture
        let minsAway = Int(target.timeIntervalSinceNow / 60)
        return VStack(alignment: .trailing, spacing: 0) {
            if minsAway <= 0 {
                Text("Now").font(.headline).monospacedDigit()
            } else if minsAway < 60 {
                Text("\(minsAway) min").font(.headline).monospacedDigit()
            } else {
                Text(target, style: .time).font(.headline).monospacedDigit()
            }
        }
    }

    private func stopChip(_ stop: NearbyStop) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stop.stopName).font(.subheadline).lineLimit(1)
            Text("\(Int(stop.distanceM)) m").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }

    private func handleSelectionChange(_ newStop: NearbyStop?) {
        nextDepartureTask?.cancel()
        nextDeparture = nil
        nextDepartureError = nil
        guard let stop = newStop else { return }
        nextDepartureTask = Task { @MainActor in
            await loadNextDeparture(stopId: stop.stopId)
        }
    }

    @MainActor
    private func loadNextDeparture(stopId: String) async {
        loadingNextDeparture = true; nextDepartureError = nil
        defer { loadingNextDeparture = false }
        do {
            let deps = try await TransLinkClient.shared.departures(
                stopId: stopId, limit: 1, windowMin: 180,
            )
            // Only commit if this is still the active selection.
            if selectedStop?.stopId == stopId {
                nextDeparture = deps.first
            }
        } catch is CancellationError {
            return
        } catch {
            nextDepartureError = error.localizedDescription
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
