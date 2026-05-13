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
    @State private var directionsShown = false
    @State private var customizeShown = false
    @State private var focusedStop: NearbyStop?
    @State private var focusedRoute: String?
    @AppStorage(TilePosition.storageKey) private var tilePositionRaw: String = TilePosition.defaultValue.rawValue
    @AppStorage(TileOrientation.storageKey) private var tileOrientationRaw: String = TileOrientation.defaultValue.rawValue
    @AppStorage(MapTileOrder.storageKey) private var tileOrderRaw: String = MapTileOrder.defaultRaw
    @AppStorage("show_buses_v1") private var showBuses: Bool = true
    @AppStorage("show_trains_v1") private var showTrains: Bool = true
    @AppStorage("show_ferries_v1") private var showFerries: Bool = true
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
                    RouteLookupView { stop, routeName in
                        focusOnRouteStop(stop, route: routeName)
                    }
                    .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $directionsShown) {
                    DirectionsView()
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $customizeShown) {
                    TilesCustomizationView(rawOrder: $tileOrderRaw)
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
        .overlay(alignment: tilePosition.alignment) {
            tileStack
                .padding(tilePosition.edgeInsets)
                .animation(.spring(duration: 0.3), value: focusedRoute)
                .animation(.spring(duration: 0.3), value: tilePosition)
                .animation(.spring(duration: 0.3), value: tileOrientation)
        }
    }

    @ViewBuilder
    private var tileStack: some View {
        switch tileOrientation {
        case .vertical:
            VStack(alignment: tilePosition.stackAlignment, spacing: 8) {
                tilesContent
            }
        case .horizontal:
            HStack(alignment: .center, spacing: 8) {
                tilesContent
            }
        }
    }

    @ViewBuilder
    private var tilesContent: some View {
        ForEach(MapTileOrder.decode(tileOrderRaw)) { tile in
            tilePill(for: tile)
        }
        if let route = focusedRoute {
            clearFocusPill(route)
                .transition(
                    .move(edge: tilePosition.transitionEdge)
                    .combined(with: .opacity),
                )
        }
    }

    private var tilePosition: TilePosition {
        TilePosition(rawValue: tilePositionRaw) ?? .defaultValue
    }

    private var tileOrientation: TileOrientation {
        TileOrientation(rawValue: tileOrientationRaw) ?? .defaultValue
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        UserAnnotation()
        // Render the focused stop separately so it doesn't double up under
        // the highlighted annotation; everything else stays as a regular Marker,
        // with mode filters applied.
        ForEach(stops.filter {
            isModeVisible($0) && $0.stopId != focusedStop?.stopId
        }) { stop in
            marker(for: stop)
        }
        if let focused = focusedStop {
            Annotation(focused.stopName, coordinate: focused.coordinate, anchor: .center) {
                FocusedStopMarker(
                    routeBadge: focusedRoute,
                    symbol: focused.modeSymbolName,
                )
            }
            .tag(focused)
        }
    }

    private func marker(for stop: NearbyStop) -> some MapContent {
        Marker(stop.stopName,
               systemImage: stop.modeSymbolName,
               coordinate: stop.coordinate)
            .tint(stop.modeTint)
            .tag(stop)
    }

    /// A stop is hidden by the user's mode filters. Priority matches the pin
    /// styling (ferry → rail → bus) so a multi-mode stop is filtered by the
    /// same mode the user sees it as.
    private func isModeVisible(_ stop: NearbyStop) -> Bool {
        if stop.isFerry { return showFerries }
        if stop.isRail  { return showTrains }
        return showBuses
    }

    // MARK: Overlays

    @ViewBuilder
    private func tilePill(for tile: MapTileKind) -> some View {
        switch tile {
        case .filters:
            filtersTilePill
        default:
            actionTilePill(for: tile)
        }
    }

    private func actionTilePill(for tile: MapTileKind) -> some View {
        Button {
            handleTileTap(tile)
        } label: {
            tilePillLabel(icon: tile.iconName, text: tile.label, iconOnly: tile.iconOnlyOnMap)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tile.label)
        .contextMenu { tileLayoutMenu }
    }

    /// The Filters tile uses `Menu` so a tap reveals the three mode toggles
    /// directly, while long-press still opens the layout / reorder controls.
    private var filtersTilePill: some View {
        Menu {
            Toggle(isOn: $showBuses) {
                Label("Buses", systemImage: "bus.fill")
            }
            Toggle(isOn: $showTrains) {
                Label("Trains", systemImage: "train.side.front.car")
            }
            Toggle(isOn: $showFerries) {
                Label("Ferries", systemImage: "ferry.fill")
            }
        } label: {
            tilePillLabel(
                icon: anyFilterActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle",
                text: MapTileKind.filters.label,
                iconOnly: MapTileKind.filters.iconOnlyOnMap,
            )
        }
        .accessibilityLabel("Filters")
        .contextMenu { tileLayoutMenu }
    }

    private func tilePillLabel(icon: String, text: String, iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            if !iconOnly {
                Text(text).fontWeight(.semibold)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, iconOnly ? 11 : 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
    }

    @ViewBuilder
    private var tileLayoutMenu: some View {
        Picker("Move tiles", selection: $tilePositionRaw) {
            ForEach(TilePosition.allCases) { pos in
                Label(pos.label, systemImage: pos.iconName)
                    .tag(pos.rawValue)
            }
        }
        Picker("Layout", selection: $tileOrientationRaw) {
            ForEach(TileOrientation.allCases) { o in
                Label(o.label, systemImage: o.iconName)
                    .tag(o.rawValue)
            }
        }
        Button {
            customizeShown = true
        } label: {
            Label("Reorder tiles…", systemImage: "list.bullet.rectangle")
        }
    }

    private var anyFilterActive: Bool {
        !showBuses || !showTrains || !showFerries
    }

    private func handleTileTap(_ tile: MapTileKind) {
        switch tile {
        case .home: resetToHome()
        case .directions: directionsShown = true
        case .route: routeLookupShown = true
        case .filters: break  // handled by Menu, not Button
        }
    }

    private func resetToHome() {
        focusedStop = nil
        focusedRoute = nil
        selectedStop = nil
        sheetShown = false
        withAnimation {
            cameraPosition = .userLocation(
                followsHeading: false,
                fallback: .region(Self.brisbaneFallback),
            )
        }
    }

    private func clearFocusPill(_ routeName: String) -> some View {
        Button {
            resetFocus()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                Text("Route \(routeName)").fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(.green, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
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

    private func focusOnRouteStop(_ stop: NearbyStop, route: String) {
        focusedStop = stop
        focusedRoute = route
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

    private func resetFocus() {
        focusedStop = nil
        focusedRoute = nil
        withAnimation {
            cameraPosition = .userLocation(
                followsHeading: false,
                fallback: .region(Self.brisbaneFallback),
            )
        }
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

/// Pulsing green badge for the stop returned by a route lookup. Sits above the
/// regular marker layer so it reads as "this is the one you searched for".
private struct FocusedStopMarker: View {
    let routeBadge: String?
    let symbol: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green, lineWidth: 3)
                .frame(width: 44, height: 44)
                .scaleEffect(pulse ? 1.7 : 1)
                .opacity(pulse ? 0 : 0.8)
                .animation(
                    .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                    value: pulse,
                )

            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                if let badge = routeBadge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Circle().fill(.green))
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .onAppear { pulse = true }
    }
}

