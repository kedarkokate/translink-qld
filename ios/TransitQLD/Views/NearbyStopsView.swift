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
    @State private var favouritesShown = false
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
    // Start on the Brisbane fallback region (not `.userLocation`) so we keep
    // explicit control of the camera. The Home button still uses
    // `.userLocation(...)` to engage follow-me mode on demand. Auto-centering
    // on the user's first GPS fix is handled in the `.onChange(initial:true)`
    // below so a location that's already available at view-appear time is
    // honoured (a plain .onChange only fires for *subsequent* changes).
    @State private var cameraPosition: MapCameraPosition = .region(brisbaneFallback)
    @State private var hasAutoCenteredOnUser = false

    static let brisbaneFallback = MKCoordinateRegion(
        center: .init(latitude: -27.4698, longitude: 153.0251),
        latitudinalMeters: 1500, longitudinalMeters: 1500,
    )

    private static let minRadiusM: Double = 150
    // 15 km cap so a zoomed-out view (e.g. panning to the Sunshine Coast or
    // Gold Coast) still pulls back a useful slice of stops. The endpoint
    // `limit: 100` clamps the result set so we don't blow up the UI.
    private static let maxRadiusM: Double = 15_000
    /// Below this latitudeDelta (~2.2 km north-south at Brisbane latitudes)
    /// we render labels next to each Marker. Above it, we drop the labels —
    /// at distant zoom they overlap into illegible stripes.
    private static let labelVisibleSpan: Double = 0.02

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
                .sheet(isPresented: $favouritesShown) {
                    FavouritesView()
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
        // Snap the camera onto the user's location on first appearance AND
        // when the first real GPS fix arrives. `initial: true` is the key —
        // RootView's `.task` starts the LocationManager before NearbyStopsView
        // is on screen, so by the time .onChange would normally first run the
        // lastLocation has often *already* been set, which a plain .onChange
        // would miss. With `initial: true` we run once with whatever value is
        // current at view-appear time, then again when location actually arrives.
        .onChange(of: locationManager.lastLocation, initial: true) { _, new in
            guard !hasAutoCenteredOnUser, let coord = new?.coordinate else { return }
            hasAutoCenteredOnUser = true
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 1500, longitudinalMeters: 1500,
                ))
            }
        }
        .overlay(alignment: tilePosition.alignment) {
            tileStack
                .padding(tilePosition.edgeInsets)
                .animation(.spring(duration: 0.3), value: focusedRoute)
                .animation(.spring(duration: 0.3), value: tilePosition)
                .animation(.spring(duration: 0.3), value: tileOrientation)
        }
        .overlay(alignment: .top) {
            emptyAreaHint
                .padding(.top, 12)
                .padding(.horizontal, 16)
        }
    }

    /// Banner that surfaces when the visible map area returns zero stops. The
    /// nearby endpoint succeeded — there just aren't any TransLink stops in
    /// what the user is looking at. (TransLink's SEQ feed doesn't cover
    /// Rockhampton, Toowoomba, or other regions outside South-East QLD.)
    @ViewBuilder
    private var emptyAreaHint: some View {
        if !loading && error == nil && stops.isEmpty && visibleRegion != nil {
            Text("No TransLink stops in this area")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                .transition(.opacity)
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
            // Horizontal layout can overflow on small devices once enough
            // tiles are enabled (we have 5: Home, Directions, Route,
            // Favourites, Filters). Wrap the row in a horizontal ScrollView
            // so the user can swipe past the screen edge to reach hidden
            // pills instead of those pills being clipped off-screen.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 8) {
                    tilesContent
                }
                .padding(.horizontal, 2)
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
        if let stop = focusedStop {
            directionsToStopPill(stop)
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
        // At coarse zoom levels every Marker's label collides with its
        // neighbours into an unreadable scribble; drop labels and just show
        // the coloured pins. MapKit's Marker uses empty string ⇒ no label.
        let label = isZoomedInForLabels ? stop.stopName : ""
        return Marker(label,
                      systemImage: stop.modeSymbolName,
                      coordinate: stop.coordinate)
            .tint(stop.modeTint)
            .tag(stop)
    }

    private var isZoomedInForLabels: Bool {
        guard let span = visibleRegion?.span else { return false }
        return span.latitudeDelta < Self.labelVisibleSpan
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
            tilePillLabel(
                icon: tile.iconName, text: tile.label,
                iconOnly: effectiveIconOnly(tile),
            )
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
                iconOnly: effectiveIconOnly(.filters),
            )
        }
        .accessibilityLabel("Filters")
        .contextMenu { tileLayoutMenu }
    }

    /// When a route is focused on the map the camera is zoomed to fit two
    /// distant points and the tile stack can crowd the screen — collapse all
    /// pills to icon-only in that mode. The clear-focus pill keeps its text
    /// because the route name is meaningful content.
    private func effectiveIconOnly(_ tile: MapTileKind) -> Bool {
        if focusedStop != nil { return true }
        return tile.iconOnlyOnMap
    }

    private func tilePillLabel(icon: String, text: String, iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            if !iconOnly {
                Text(text)
                    .fontWeight(.semibold)
                    // Without lineLimit + fixedSize a horizontal HStack of
                    // pills that overflows the screen squishes each pill,
                    // and the inner Text wraps character-by-character into
                    // a vertical stripe of letters. Clamp to one line and
                    // let the pill keep its natural width.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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
        case .favourites: favouritesShown = true
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

    /// Walking-directions pill that hands off to the user's chosen map app.
    /// Apple Maps is always offered; Google Maps is offered too if installed
    /// (detected via `canOpenURL` with `LSApplicationQueriesSchemes`).
    @ViewBuilder
    private func directionsToStopPill(_ stop: NearbyStop) -> some View {
        if hasGoogleMapsInstalled {
            Menu {
                Button { openAppleMaps(to: stop) } label: {
                    Label("Open in Apple Maps", systemImage: "applelogo")
                }
                Button { openGoogleMaps(to: stop) } label: {
                    Label("Open in Google Maps", systemImage: "globe")
                }
            } label: {
                directionsToStopPillLabel
            }
        } else {
            Button {
                openAppleMaps(to: stop)
            } label: {
                directionsToStopPillLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var directionsToStopPillLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.walk.diamond.fill")
            Text("Walk").fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(.blue, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private var hasGoogleMapsInstalled: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private func openAppleMaps(to stop: NearbyStop) {
        let dst = MKMapItem(placemark: MKPlacemark(coordinate: stop.coordinate))
        dst.name = stop.stopName
        // Omitting the source uses the device's current location automatically.
        MKMapItem.openMaps(with: [dst], launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
        ])
    }

    private func openGoogleMaps(to stop: NearbyStop) {
        let coord = "\(stop.stopLat),\(stop.stopLon)"
        let encodedName = stop.stopName
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // Empty saddr → current location. directionsmode=walking matches the
        // pill's "Walk" labelling; the user can change mode inside the app.
        let raw = "comgooglemaps://?saddr=&daddr=\(coord)&directionsmode=walking&q=\(encodedName)"
        guard let url = URL(string: raw) else { return }
        UIApplication.shared.open(url)
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

