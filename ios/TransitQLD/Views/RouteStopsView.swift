import SwiftUI

/// Lightweight identifiable wrapper so `.sheet(item:)` can present this view
/// for a given route short name (`"61"`, `"M2"`, ...).
struct RouteStopsRequest: Identifiable, Hashable {
    let shortName: String
    /// Optional headsign of the trip the user tapped, so the route header
    /// pill reflects their chosen direction (e.g. "Ipswich" rather than
    /// the colour-family fallback "Caboolture" on a through-route).
    let headsign: String?
    var id: String { shortName + "|" + (headsign ?? "") }

    init(shortName: String, headsign: String? = nil) {
        self.shortName = shortName
        self.headsign = headsign
    }
}

struct RouteStopsView: View {
    let shortName: String
    let selectedHeadsign: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(FavouritesStore.self) private var favourites

    init(shortName: String, selectedHeadsign: String? = nil) {
        self.shortName = shortName
        self.selectedHeadsign = selectedHeadsign
    }

    @State private var response: RouteStopsResponse?
    @State private var loading = false
    @State private var error: String?
    @State private var selectedStop: NearbyStop?

    var body: some View {
        NavigationStack {
            Group {
                if let r = response {
                    contentList(r)
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                        Text(error).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Route \(shortName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Close")
                }
            }
            .task(id: shortName) { await load() }
            .sheet(item: $selectedStop) { stop in
                StopDetailView(stop: stop)
                    .presentationDetents([.fraction(0.45), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func contentList(_ r: RouteStopsResponse) -> some View {
        List {
            if let longName = r.routeLongName {
                Section {
                    HStack(spacing: 12) {
                        Text(headerLabel(r))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(foregroundForRoute(r))
                            .background(tintForRoute(r),
                                        in: RoundedRectangle(cornerRadius: 8))
                        Text(longName)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(r.directions) { dir in
                Section(header: directionHeader(dir, response: r)) {
                    ForEach(dir.stops) { stop in
                        HStack(spacing: 12) {
                            Button {
                                selectedStop = stop.asNearbyStop()
                            } label: {
                                stopRow(stop)
                            }
                            .buttonStyle(.plain)
                            favouriteToggle(for: stop, in: dir, response: r)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func directionHeader(_ dir: RouteDirection, response: RouteStopsResponse) -> some View {
        HStack(spacing: 6) {
            Image(systemName: routeIcon(response.routeType))
                .foregroundStyle(tintForRoute(response))
            Text("Towards \(directionLabel(dir, type: response.routeType))")
                .font(.subheadline.weight(.semibold))
                .textCase(nil)
        }
    }

    private func headerLabel(_ r: RouteStopsResponse) -> String {
        if r.routeType == RouteType.rail.rawValue || r.routeType == RouteType.subway.rawValue {
            // Honour the direction the user tapped first; otherwise fall back
            // to the line family parsed from route_long_name.
            if let h = trainPillLabel(headsign: selectedHeadsign) { return h }
            if let line = trainLine(longName: r.routeLongName, routeColor: r.routeColor) {
                return line.pillName
            }
        }
        return r.routeShortName
    }

    private func directionLabel(_ dir: RouteDirection, type: Int) -> String {
        guard let headsign = dir.headsign, !headsign.isEmpty else { return "—" }
        if type == RouteType.rail.rawValue || type == RouteType.subway.rawValue {
            return trainPillLabel(headsign: headsign) ?? headsign
        }
        return headsign
    }

    private func foregroundForRoute(_ r: RouteStopsResponse) -> Color {
        RouteStyle.foreground(routeType: r.routeType, routeTextColor: r.routeTextColor)
    }

    private func tintForRoute(_ r: RouteStopsResponse) -> Color {
        if RouteStyle.isTrain(r.routeType) {
            let line = trainLine(longName: r.routeLongName, routeColor: r.routeColor)
            // The City Loop's GTFS route_color (A0A0A0, a flat "no brand"
            // grey) is overridden by our own colour so the pill stands out.
            if line?.pillName == "City Loop", let c = Color(gtfsHex: line?.hex) {
                return c
            }
        }
        return RouteStyle.tint(routeType: r.routeType, routeColor: r.routeColor,
                                routeLongName: r.routeLongName)
    }

    /// Trailing-edge star on each stop row. Bookmarks "this route at this
    /// stop heading this direction" — the same shape as the favourite the
    /// star on StopDetailView's departure rows creates, so they dedupe via
    /// FavouritesStore.service(matching:) naturally.
    @ViewBuilder
    private func favouriteToggle(
        for stop: RouteStop,
        in dir: RouteDirection,
        response r: RouteStopsResponse,
    ) -> some View {
        let isFav = favourites.isServiceFavourite(
            stopId: stop.stopId, route: r.routeShortName,
            headsign: dir.headsign, secondsSinceMidnight: nil,
        )
        Button {
            favourites.toggleService(FavouriteService(
                stopId: stop.stopId, stopName: stop.stopName,
                stopCode: stop.stopCode,
                stopLat: stop.stopLat, stopLon: stop.stopLon,
                // The RouteStops endpoint doesn't surface per-stop
                // route_types (the comma-string of modes); leaving it nil
                // means the favourites list falls back to the route's
                // own route_type when picking an icon, which is correct.
                routeTypes: nil,
                routeShortName: r.routeShortName,
                routeLongName: r.routeLongName,
                routeType: r.routeType,
                routeColor: r.routeColor,
                routeTextColor: r.routeTextColor,
                headsign: dir.headsign,
                scheduledSecondsSinceMidnight: nil,
            ))
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.system(size: 17))
                .foregroundStyle(isFav ? .yellow : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFav ? "Remove favourite" : "Favourite this stop on route \(r.routeShortName)")
    }

    @ViewBuilder
    private func stopRow(_ stop: RouteStop) -> some View {
        HStack(spacing: 12) {
            Text("\(stop.stopSequence)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .trailing)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.stopName).lineLimit(2)
                if let code = stop.stopCode {
                    Text("Stop \(code)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func routeIcon(_ rt: Int) -> String {
        RouteStyle.icon(routeType: rt)
    }

    @MainActor
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            response = try await TransLinkClient.shared.routeStops(shortName: shortName)
        } catch is CancellationError {
            return
        } catch {
            self.error = "Couldn't load stops for route \(shortName): \(error.localizedDescription)"
        }
    }
}
