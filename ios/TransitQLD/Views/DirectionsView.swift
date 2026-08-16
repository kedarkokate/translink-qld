import SwiftUI
import MapKit
import CoreLocation

struct DirectionsView: View {
    /// Optional binding to the user's pinned journey. When set, the result
    /// list shows a Pin / Unpin toggle on each row; tapping it captures or
    /// clears the in-memory snapshot held by `NearbyStopsView` so the user
    /// can dismiss the Directions sheet without losing the chosen plan.
    @Binding var pinnedJourney: JourneyOption?

    /// Called when the user taps a stop name in a result row. The host
    /// (`NearbyStopsView`) typically dismisses this sheet and focuses the
    /// map on the chosen stop with a green pulse, matching the Route
    /// Lookup → focus-on-map behaviour.
    let onStopTap: ((NearbyStop, String) -> Void)?

    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppConfig.walkToMKey)   private var walkToM:   Int = AppConfig.defaultWalkM
    @AppStorage(AppConfig.walkFromMKey) private var walkFromM: Int = AppConfig.defaultWalkM

    @State private var from: SearchLocation?
    @State private var to: SearchLocation?
    @State private var pickerKind: PickerKind?
    @State private var options: [JourneyOption] = []
    @State private var searching = false
    @State private var error: String?
    @State private var routeStopsRequest: RouteStopsRequest?

    init(
        pinnedJourney: Binding<JourneyOption?> = .constant(nil),
        onStopTap: ((NearbyStop, String) -> Void)? = nil,
    ) {
        self._pinnedJourney = pinnedJourney
        self.onStopTap = onStopTap
    }

    enum PickerKind: Identifiable {
        case from, to
        var id: Int { self == .from ? 0 : 1 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                pickersHeader

                if searching && options.isEmpty {
                    Spacer()
                    ProgressView("Searching transit options…")
                    Spacer()
                } else if let error, options.isEmpty {
                    Spacer()
                    errorView(error)
                    Spacer()
                } else if !options.isEmpty {
                    optionsList
                } else {
                    Spacer()
                    emptyHint
                    Spacer()
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 12)
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
            // Explicit visible background so the Close button sits on an
            // opaque bar rather than letting content scroll under it (which
            // in dark mode made the Close text overlap the From/To rows).
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear {
                if from == nil, let loc = locationManager.lastLocation?.coordinate {
                    from = .currentLocation(loc)
                }
            }
            .sheet(item: $routeStopsRequest) { req in
                RouteStopsView(shortName: req.shortName, selectedHeadsign: req.headsign)
            }
            .sheet(item: $pickerKind) { kind in
                LocationPickerView(
                    near: locationManager.lastLocation?.coordinate,
                    allowCurrentLocation: kind == .from,
                    title: kind == .from ? "Start" : "Destination",
                ) { picked in
                    if kind == .from { from = picked } else { to = picked }
                    Task { await searchIfReady() }
                }
            }
        }
    }

    // MARK: From/To pickers

    private var pickersHeader: some View {
        VStack(spacing: 10) {
            pickerButton(label: "From", location: from, placeholder: "Pick a start") {
                pickerKind = .from
            }
            pickerButton(label: "To", location: to, placeholder: "Pick a destination") {
                pickerKind = .to
            }
            HStack {
                Button {
                    swap(&from, &to)
                    Task { await searchIfReady() }
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(from == nil && to == nil)

                Spacer()

                Button {
                    Task { await search() }
                } label: {
                    Label("Get directions", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(from == nil || to == nil || searching)
            }
        }
        .padding(.horizontal)
    }

    private func pickerButton(
        label: String, location: SearchLocation?, placeholder: String,
        onTap: @escaping () -> Void,
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: location?.symbolName ?? "circle")
                    .foregroundStyle(location == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.blue))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(location?.title ?? placeholder)
                        .font(.subheadline)
                        .foregroundStyle(location == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty / error / list

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.swap").font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Set both From and To to see transit options.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .fixedSize(horizontal: false, vertical: true)
            if from != nil && to != nil {
                Button {
                    openInAppleMaps()
                } label: {
                    Label("Open in Apple Maps", systemImage: "map.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var optionsList: some View {
        List {
            ForEach(Array(options.enumerated()), id: \.element.id) { idx, option in
                Section {
                    optionRow(option, isBest: idx == 0)
                }
            }
            Section {
                Button {
                    openInAppleMaps()
                } label: {
                    Text("Open in Apple Maps")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
            } footer: {
                Text("For transfers or longer trips, Apple Maps gives full step-by-step directions.")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func optionRow(_ option: JourneyOption, isBest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                routeBadge(option.route, headsign: option.headsign)
                Text("\(option.totalMinutes) min")
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if option.isRealtime {
                    HStack(spacing: 3) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("Live")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption2)
                    .foregroundStyle(.green)
                }
                Spacer(minLength: 4)
                pinButton(for: option)
                if isBest {
                    Text("Best")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(.green, in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if let headsign = option.headsign {
                Text("→ \(headsign)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                let leg1RouteName = option.route.routeShortName ?? ""
                let leg2RouteName = option.transfer?.route.routeShortName ?? ""

                journeyStep(
                    icon: "figure.walk", iconColor: .secondary,
                    primary: "Walk \(option.walkToMinutes) min to \(option.board.stopName)",
                    secondary: "\(option.board.walkDistanceM) m",
                    onTap: onStopTap.map { handler in
                        { handler(nearbyStop(from: option.board, routeType: option.route.routeType), leg1RouteName) }
                    },
                )
                // Leg 1's ride. For direct journeys this is the full ride
                // from board to the final destination; for transfer
                // journeys it's the first leg ending at the hub.
                journeyStep(
                    icon: routeIcon(option.route.routeType),
                    iconColor: routeTint(option.route, headsign: option.headsign),
                    primary: "Catch \(routeLabel(option.route, headsign: option.headsign)) at \(formatTime(option.board.effectiveTime))",
                    secondary: leg1Secondary(option),
                )
                if let transfer = option.transfer {
                    journeyStep(
                        icon: "arrow.triangle.swap",
                        iconColor: .orange,
                        primary: "Transfer at \(transfer.board.stopName)",
                        secondary: transferSecondary(transfer),
                        onTap: onStopTap.map { handler in
                            { handler(nearbyStop(from: transfer.board, routeType: transfer.route.routeType), leg2RouteName) }
                        },
                    )
                    journeyStep(
                        icon: routeIcon(transfer.route.routeType),
                        iconColor: routeTint(transfer.route, headsign: transfer.headsign),
                        primary: "Catch \(routeLabel(transfer.route, headsign: transfer.headsign)) at \(formatTime(transfer.board.effectiveTime))",
                        secondary: "Ride to \(transfer.alight.stopName) → arrive \(formatTime(transfer.alight.effectiveTime))",
                    )
                }
                let finalRouteName = option.transfer != nil ? leg2RouteName : leg1RouteName
                let finalRouteType = option.transfer?.route.routeType ?? option.route.routeType
                journeyStep(
                    icon: "figure.walk", iconColor: .secondary,
                    primary: "Walk \(option.walkFromMinutes) min from \(finalAlight(option).stopName)",
                    secondary: "\(finalAlight(option).walkDistanceM) m",
                    onTap: onStopTap.map { handler in
                        { handler(nearbyStop(from: finalAlight(option), routeType: finalRouteType), finalRouteName) }
                    },
                )
            }

            if let delay = option.delaySeconds, abs(delay) >= 60 {
                Text(delay > 0
                     ? "Running \(delay / 60) min late"
                     : "Running \(abs(delay) / 60) min early")
                    .font(.caption)
                    .foregroundStyle(delay > 0 ? .orange : .green)
            }
        }
    }

    /// Secondary text for the first ride leg. For direct journeys this is
    /// the full transit duration + final arrival time. For transfer
    /// journeys we only describe leg 1 (hub arrival); transitMinutes spans
    /// both legs so we recompute leg 1's duration from its timestamps.
    private func leg1Secondary(_ option: JourneyOption) -> String {
        guard option.hasTransfer else {
            return "Ride \(option.transitMinutes) min → arrive \(formatTime(option.alight.effectiveTime))"
        }
        let mins = Int(option.alight.effectiveTime.timeIntervalSince(option.board.effectiveTime) / 60)
        return "Ride \(mins) min → arrive \(option.alight.stopName) at \(formatTime(option.alight.effectiveTime))"
    }

    private func transferSecondary(_ transfer: JourneyTransferLeg) -> String {
        if transfer.waitMinutes <= 1 { return "Cross-platform transfer" }
        return "Wait \(transfer.waitMinutes) min, then board \(transfer.route.displayName)"
    }

    private func finalAlight(_ option: JourneyOption) -> JourneyStopRef {
        option.transfer?.alight ?? option.alight
    }

    /// One row of a journey breakdown. When `onTap` is provided the row
    /// renders its primary text in `.accentColor` with a trailing chevron
    /// and becomes tappable — used for "Walk to X / from X" and "Transfer
    /// at X" steps so the user can jump to that stop on the map.
    private func journeyStep(
        icon: String, iconColor: Color,
        primary: String, secondary: String,
        onTap: (() -> Void)? = nil,
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(primary).font(.subheadline)
                    .foregroundStyle(onTap == nil ? Color.primary : Color.accentColor)
                Text(secondary).font(.caption).foregroundStyle(.secondary)
            }
            if onTap != nil {
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    /// Pin / unpin toggle on each result row. Pinning captures this journey
    /// option as an in-memory snapshot on the host so the user can dismiss
    /// the Directions sheet, navigate the map, and refer back to the plan
    /// via the pinned banner above the map. Tapping while pinned (filled
    /// pin icon) unpins. Only ever one pinned journey at a time — re-tapping
    /// a different row replaces the pin.
    @ViewBuilder
    private func pinButton(for option: JourneyOption) -> some View {
        let isPinned = pinnedJourney?.id == option.id
        Button {
            pinnedJourney = isPinned ? nil : option
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.subheadline)
                .foregroundStyle(isPinned ? .orange : .secondary)
                .rotationEffect(.degrees(isPinned ? 0 : 45))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPinned ? "Unpin journey" : "Pin this journey")
    }

    private func nearbyStop(from ref: JourneyStopRef, routeType: Int) -> NearbyStop {
        NearbyStop(journeyStop: ref, routeType: routeType)
    }

    private func routeBadge(_ route: JourneyRoute, headsign: String? = nil) -> some View {
        Button {
            if let name = route.routeShortName, !name.isEmpty {
                routeStopsRequest = RouteStopsRequest(shortName: name, headsign: headsign)
            }
        } label: {
            Text(routeLabel(route, headsign: headsign))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.7)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(routeForeground(route))
                .background(routeTint(route, headsign: headsign),
                            in: RoundedRectangle(cornerRadius: 9))
                .frame(minWidth: 56, maxWidth: 140, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(route.routeShortName?.isEmpty ?? true)
    }

    /// Pill / step label for a journey route. Trains get the destination /
    /// line name; other modes keep their existing short name.
    private func routeLabel(_ route: JourneyRoute, headsign: String?) -> String {
        RouteStyle.label(
            routeType: route.routeType, routeShortName: route.routeShortName,
            routeLongName: route.routeLongName, routeColor: route.routeColor,
            headsign: headsign,
        )
    }

    /// Background / icon tint for a journey route. Trains use the GTFS
    /// `route_color` (or the mapped line colour) so each line gets its
    /// official TransLink hue.
    private func routeTint(_ route: JourneyRoute, headsign: String?) -> Color {
        RouteStyle.tint(
            routeType: route.routeType, routeColor: route.routeColor,
            routeLongName: route.routeLongName, headsign: headsign,
        )
    }

    /// Foreground (text) colour for the pill — honours GTFS `route_text_color`
    /// when present so yellow Airport / Gold Coast pills get black text.
    private func routeForeground(_ route: JourneyRoute) -> Color {
        RouteStyle.foreground(routeType: route.routeType, routeTextColor: route.routeTextColor)
    }

    private func routeIcon(_ rt: Int) -> String {
        RouteStyle.icon(routeType: rt)
    }

    private func formatTime(_ d: Date) -> String {
        d.timeOfDay
    }

    // MARK: Search

    @MainActor
    private func searchIfReady() async {
        if from != nil && to != nil { await search() }
    }

    @MainActor
    private func search() async {
        guard let f = from, let t = to else { return }
        searching = true; error = nil; options = []
        defer { searching = false }
        do {
            let results = try await TransLinkClient.shared.planJourney(
                from: f.coordinate, to: t.coordinate,
                walkToM: walkToM, walkFromM: walkFromM,
            )
            if results.isEmpty {
                error = noRoutesMessage
            } else {
                options = results
            }
        } catch {
            self.error = "Couldn't plan a journey: \(error.localizedDescription)\n\n\(noRoutesMessage)"
        }
    }

    private var noRoutesMessage: String {
        """
        No transit options found within \(walkToM) m to the stop or \
        \(walkFromM) m from the stop, in the next 90 minutes.

        Try increasing your walk distances in Settings, or open Apple \
        Maps below for full multi-modal directions.
        """
    }

    private func openInAppleMaps() {
        guard let f = from, let t = to else { return }
        TransitDirectionsService.openInAppleMaps(
            from: f.coordinate, fromName: f.title,
            to: t.coordinate, toName: t.title,
        )
    }

}
