import SwiftUI

/// Vertical stack of "stop cards". Each card shows a favourite stop together
/// with the favourite services at that stop and the next 2 upcoming arrival
/// times of each. Stops that aren't themselves favourited but have a
/// favourite service attached still get a card, so nothing is hidden.
struct FavouritesView: View {
    @Environment(FavouritesStore.self) private var favourites
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var departuresByStop: [String: [Departure]] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var selectedStop: NearbyStop?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    emptyState
                } else {
                    cardStack
                }
            }
            .navigationTitle("Favourites")
            .navigationBarTitleDisplayMode(.inline)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await reload() } } label: {
                        if loading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(loading)
                }
            }
            .task {
                await reload()
                startAutoRefresh()
            }
            .onDisappear { refreshTask?.cancel() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await reload() }
                    startAutoRefresh()
                } else {
                    refreshTask?.cancel()
                }
            }
            .sheet(item: $selectedStop) { stop in
                StopDetailView(stop: stop)
                    .presentationDetents([.fraction(0.45), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "star")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No favourites yet")
                .font(.headline)
            Text("Tap the star on a stop or a service to add it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grouping

    /// One entry per stop the user cares about — i.e. any stop that is
    /// either favourited directly, or referenced by a favourited service.
    private struct StopGroup: Identifiable {
        let stopId: String
        let stopName: String
        let stopCode: String?
        let stopLat: Double
        let stopLon: Double
        let routeTypes: String?
        let isStopFavourite: Bool
        let services: [FavouriteService]

        var id: String { stopId }

        func asNearbyStop() -> NearbyStop {
            NearbyStop(
                stopId: stopId, stopCode: stopCode, stopName: stopName,
                lat: stopLat, lon: stopLon, routeTypes: routeTypes, distanceM: 0,
            )
        }
    }

    private var groups: [StopGroup] {
        // Group services by stopId.
        let svcByStop = Dictionary(grouping: favourites.services, by: { $0.stopId })
        let favStopMap = Dictionary(uniqueKeysWithValues: favourites.stops.map { ($0.stopId, $0) })
        let allIds = Set(favourites.stops.map(\.stopId)).union(svcByStop.keys)

        // Build groups, preferring the cached FavouriteStop record for
        // identity fields, falling back to the first service that mentions
        // the stop for stops that exist only via a service favourite.
        var result: [StopGroup] = []
        for stopId in allIds {
            // Route-at-stop favourites (no time) sort first, then time-specific
            // favourites in chronological order.
            let svcs = (svcByStop[stopId] ?? []).sorted { a, b in
                switch (a.scheduledSecondsSinceMidnight, b.scheduledSecondsSinceMidnight) {
                case (nil, nil): return a.addedAt < b.addedAt
                case (nil, _?): return true
                case (_?, nil): return false
                case let (x?, y?): return x < y
                }
            }
            if let fav = favStopMap[stopId] {
                result.append(StopGroup(
                    stopId: fav.stopId, stopName: fav.stopName,
                    stopCode: fav.stopCode, stopLat: fav.lat, stopLon: fav.lon,
                    routeTypes: fav.routeTypes, isStopFavourite: true,
                    services: svcs,
                ))
            } else if let svc = svcs.first {
                result.append(StopGroup(
                    stopId: svc.stopId, stopName: svc.stopName,
                    stopCode: svc.stopCode, stopLat: svc.stopLat, stopLon: svc.stopLon,
                    routeTypes: svc.routeTypes, isStopFavourite: false,
                    services: svcs,
                ))
            }
        }
        // Favourited stops first, then the rest. Within each, earliest-added first.
        return result.sorted { a, b in
            if a.isStopFavourite != b.isStopFavourite { return a.isStopFavourite }
            return a.stopName.localizedCaseInsensitiveCompare(b.stopName) == .orderedAscending
        }
    }

    // MARK: - Card stack

    @ViewBuilder
    private var cardStack: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                ForEach(groups) { g in
                    card(g)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .refreshable { await reload() }
    }

    @ViewBuilder
    private func card(_ g: StopGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader(g)
            if !g.services.isEmpty {
                Divider()
                VStack(spacing: 10) {
                    ForEach(Array(g.services.enumerated()), id: \.element.id) { idx, svc in
                        serviceRow(svc, departures: departuresByStop[g.stopId] ?? [])
                        if idx < g.services.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Card header (stop)

    @ViewBuilder
    private func cardHeader(_ g: StopGroup) -> some View {
        let modeStop = g.asNearbyStop()
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: modeStop.modeSymbolName)
                .foregroundStyle(modeStop.modeTint)
                .frame(width: 28)
            Button {
                selectedStop = g.asNearbyStop()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.stopName)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let code = g.stopCode {
                        Text("Stop \(code)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            stopStarButton(g)
        }
    }

    private func stopStarButton(_ g: StopGroup) -> some View {
        Button {
            if g.isStopFavourite {
                favourites.removeStop(stopId: g.stopId)
            } else {
                favourites.addStop(FavouriteStop(
                    stopId: g.stopId, stopName: g.stopName,
                    stopCode: g.stopCode, routeTypes: g.routeTypes,
                    lat: g.stopLat, lon: g.stopLon,
                ))
            }
        } label: {
            Image(systemName: g.isStopFavourite ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(g.isStopFavourite ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(g.isStopFavourite
                            ? "Remove favourite stop"
                            : "Favourite this stop")
    }

    // MARK: - Service row

    @ViewBuilder
    private func serviceRow(_ svc: FavouriteService, departures: [Departure]) -> some View {
        let upcoming = nextOccurrences(svc: svc, in: departures, limit: 2)
        HStack(alignment: .top, spacing: 12) {
            serviceBadge(svc)
            VStack(alignment: .leading, spacing: 3) {
                Text(svc.headsign ?? svc.routeLongName ?? svc.routeShortName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let t = svc.timeLabel {
                    Text("Scheduled \(t)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Any departure")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if upcoming.isEmpty {
                    Text(loading ? "Loading…" : "No upcoming runs in the next 48 h")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    upcomingTimes(upcoming)
                }
            }
            Spacer(minLength: 6)
            serviceStarButton(svc)
        }
    }

    @ViewBuilder
    private func upcomingTimes(_ deps: [Departure]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(deps) { d in
                HStack(spacing: 6) {
                    Text(formatArrival(d))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    if let delay = d.delaySeconds, abs(delay) >= 60 {
                        Text(delay > 0
                             ? "(\(delay / 60) min late)"
                             : "(\(abs(delay) / 60) min early)")
                            .font(.caption2)
                            .foregroundStyle(delay > 0 ? .orange : .green)
                    }
                    if d.isRealtime {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func serviceStarButton(_ svc: FavouriteService) -> some View {
        Button {
            favourites.removeService(id: svc.id)
        } label: {
            Image(systemName: "star.fill")
                .font(.system(size: 17))
                .foregroundStyle(.yellow)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove favourite service")
    }

    // MARK: - Helpers

    /// "Today 07:42", "Tomorrow 07:42", "Wed 07:42" — Brisbane-local clock.
    private func formatArrival(_ dep: Departure) -> String {
        let date = dep.effectiveDeparture
        let time = date.timeOfDay
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        return "\(weekday) \(time)"
    }

    private func nextOccurrences(
        svc: FavouriteService, in deps: [Departure], limit: Int,
    ) -> [Departure] {
        let now = Date()
        let isTrain = RouteStyle.isTrain(svc.routeType)
        return deps
            .filter { d in
                guard !d.isCancelled,
                      d.effectiveDeparture > now,
                      (d.headsign ?? "") == (svc.headsign ?? "") else { return false }
                // Brisbane train route_short_names are directional (e.g. an
                // outbound Springfield service is "RPSP" coming through-routed
                // from Redcliffe Peninsula, not the legacy "BRSP"). Matching
                // by route_color groups all directional variants of one line.
                // Buses/ferries have stable short_names — keep the strict match.
                if isTrain {
                    if (d.routeColor ?? "") != (svc.routeColor ?? "") {
                        return false
                    }
                } else if (d.routeShortName ?? "") != svc.routeShortName {
                    return false
                }
                // Time-specific favourite filters to the matching scheduled
                // time-of-day; route-at-stop favourite (time=nil) accepts any
                // upcoming run of this (route, direction).
                if let target = svc.scheduledSecondsSinceMidnight {
                    return abs(d.brisbaneSecondsSinceMidnight - target) <= 120
                }
                return true
            }
            .sorted { $0.effectiveDeparture < $1.effectiveDeparture }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Loading

    @MainActor
    private func reload() async {
        let stopIds = Array(Set(groups.map(\.stopId)))
        guard !stopIds.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        await withTaskGroup(of: (String, [Departure]).self) { group in
            for stopId in stopIds {
                group.addTask {
                    do {
                        // 48h window so commutes that only run weekday-mornings
                        // still show their next 1–2 occurrences when the user
                        // checks in the afternoon or on a weekend.
                        let deps = try await TransLinkClient.shared.departures(
                            stopId: stopId, limit: 200, windowMin: 2880,
                        )
                        return (stopId, deps)
                    } catch {
                        return (stopId, [])
                    }
                }
            }
            var next: [String: [Departure]] = [:]
            for await (stopId, deps) in group {
                next[stopId] = deps
            }
            departuresByStop = next
        }
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                await reload()
            }
        }
    }

    // MARK: - Service badge

    private func serviceBadge(_ svc: FavouriteService) -> some View {
        let label = RouteStyle.label(
            routeType: svc.routeType, routeShortName: svc.routeShortName,
            routeLongName: svc.routeLongName, routeColor: svc.routeColor,
            headsign: svc.headsign,
        )
        let bg = RouteStyle.tint(
            routeType: svc.routeType, routeColor: svc.routeColor,
            routeLongName: svc.routeLongName, headsign: svc.headsign,
        )
        let fg = RouteStyle.foreground(routeType: svc.routeType, routeTextColor: svc.routeTextColor)
        return Text(label)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: 8))
            .frame(minWidth: 64)
    }
}
