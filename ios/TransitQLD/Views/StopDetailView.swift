import SwiftUI

struct StopDetailView: View {
    let stop: NearbyStop

    @Environment(FavouritesStore.self) private var favourites
    @State private var detail: StopDetail?
    @State private var departures: [Departure] = []
    @State private var nextServicePeek: Departure?
    @State private var loading = false
    @State private var error: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var routeStopsRequest: RouteStopsRequest?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !grouped.isEmpty {
                        upcomingSection
                    } else if !loading {
                        noUpcomingSection
                    }

                    if let routes = detail?.routes, !routes.isEmpty {
                        allRoutesSection(routes)
                    }

                    if loading && departures.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }

                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: stop.stopId) {
                await loadAll()
                startAutoRefresh()
            }
            .onDisappear { refreshTask?.cancel() }
            .sheet(item: $routeStopsRequest) { req in
                RouteStopsView(shortName: req.shortName, selectedHeadsign: req.headsign)
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stop.stopName)
                    .font(.largeTitle).fontWeight(.bold)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = stop.stopCode {
                    Text("Stop \(code)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            favouriteStopButton
        }
    }

    private var favouriteStopButton: some View {
        let isFav = favourites.isStopFavourite(stopId: stop.stopId)
        return Button {
            if isFav {
                favourites.removeStop(stopId: stop.stopId)
            } else {
                favourites.addStop(FavouriteStop(
                    stopId: stop.stopId,
                    stopName: stop.stopName,
                    stopCode: stop.stopCode,
                    routeTypes: stop.routeTypes,
                    lat: stop.stopLat, lon: stop.stopLon,
                ))
            }
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.title2)
                .foregroundStyle(isFav ? .yellow : .secondary)
        }
        .accessibilityLabel(isFav ? "Remove favourite stop" : "Favourite this stop")
        .buttonStyle(.plain)
    }

    // MARK: Upcoming departures (grouped by route + headsign)

    private var grouped: [DepartureGroup] {
        var byKey: [String: DepartureGroup] = [:]
        var keyOrder: [String] = []
        let sorted = departures
            .filter { !$0.isCancelled }
            .sorted { $0.effectiveDeparture < $1.effectiveDeparture }
        for dep in sorted {
            // Trains: group by (route_color, headsign) so a through-routed
            // line never splits into two rows. The Brisbane network often has
            // multiple route_ids for what users see as one line+direction
            // (e.g. "Springfield Central" comes through-routed as RPSP from
            // Redcliffe Peninsula and, more rarely, as BRSP from Brisbane).
            // Buses/ferries keep grouping by route_id since their short_names
            // are stable per route.
            let isTrain = RouteStyle.isTrain(dep.routeType)
            let routeKey = isTrain
                ? "color:\(dep.routeColor ?? "")"
                : "id:\(dep.routeId)"
            let key = "\(routeKey)|\(dep.headsign ?? "")"
            if byKey[key] == nil {
                byKey[key] = DepartureGroup(
                    key: key, badge: dep.routeBadge,
                    routeShortName: dep.routeShortName,
                    routeLongName: dep.routeLongName,
                    routeColor: dep.routeColor,
                    routeTextColor: dep.routeTextColor,
                    headsign: dep.headsign, routeType: dep.routeType, times: [],
                )
                keyOrder.append(key)
            }
            byKey[key]!.times.append(dep)
        }
        return keyOrder.compactMap { byKey[$0] }
    }

    @ViewBuilder
    private var noUpcomingSection: some View {
        let beyond24h = nextServicePeek.map {
            $0.effectiveDeparture > Date().addingTimeInterval(86_400)
        } ?? false

        VStack(alignment: .leading, spacing: 12) {
            // Primary message: escalate to "no service today" when the next
            // departure is more than 24 hours away.
            Text(beyond24h
                 ? "No service in the next 24 hours."
                 : "No upcoming departures in the next two hours.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let peek = nextServicePeek {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(beyond24h ? "NEXT SCHEDULED SERVICE" : "NEXT SERVICE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 14) {
                        routeBadge(text: peek.routeBadge, type: peek.routeType,
                                   prominent: true, shortName: peek.routeShortName,
                                   routeColor: peek.routeColor,
                                   routeTextColor: peek.routeTextColor,
                                   longName: peek.routeLongName,
                                   headsign: peek.headsign)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peek.headsign ?? peek.routeLongName ?? "—")
                                .font(.subheadline).lineLimit(2)
                            Text(formattedFutureTime(peek.effectiveDeparture))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func formattedFutureTime(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.timeOfDay
        if cal.isDateInToday(date) { return "Today at \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(time)" }
        // Beyond tomorrow: include the date so "Wednesday" is unambiguous
        // when it could be this week or next week.
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let dayMonth = date.formatted(.dateTime.day().month(.abbreviated))
        return "\(weekday) \(dayMonth) at \(time)"
    }

    @ViewBuilder
    private var upcomingSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(grouped.enumerated()), id: \.element.id) { idx, group in
                upcomingRow(group)
                if idx < grouped.count - 1 {
                    Divider().padding(.vertical, 8)
                }
            }
        }
    }

    private func upcomingRow(_ group: DepartureGroup) -> some View {
        HStack(alignment: .center, spacing: 14) {
            routeBadge(text: group.badge, type: group.routeType, prominent: true,
                       shortName: group.routeShortName,
                       routeColor: group.routeColor,
                       routeTextColor: group.routeTextColor,
                       longName: group.routeLongName,
                       headsign: group.headsign)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.headsign ?? "—")
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if group.times.first?.isRealtime == true {
                    HStack(spacing: 3) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("Live")
                    }.font(.caption2).foregroundStyle(.green)
                }
            }
            Spacer(minLength: 8)
            Text(formatTimes(group.times))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
            favouriteServiceButton(group)
        }
        .padding(.vertical, 6)
    }

    /// Trailing-edge star on an upcoming row. A simple toggle: tap to add
    /// (or remove) a "route at this stop" favourite. The time-specific
    /// variant — favourite the 07:42 specifically — was removed in v1.0
    /// because picking the exact next-occurrence as the time felt arbitrary;
    /// the broader bookmark is what users actually wanted.
    private func favouriteServiceButton(_ group: DepartureGroup) -> some View {
        let routeName = group.routeShortName ?? ""
        let isFav = favourites.isServiceFavourite(
            stopId: stop.stopId, route: routeName,
            headsign: group.headsign, secondsSinceMidnight: nil,
        )
        return Button {
            favourites.toggleService(buildFavourite(group: group))
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.system(size: 18))
                .foregroundStyle(isFav ? .yellow : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFav ? "Remove favourite" : "Favourite this route at this stop")
    }

    private func buildFavourite(group: DepartureGroup) -> FavouriteService {
        FavouriteService(
            stopId: stop.stopId, stopName: stop.stopName,
            stopCode: stop.stopCode,
            stopLat: stop.stopLat, stopLon: stop.stopLon,
            routeTypes: stop.routeTypes,
            routeShortName: group.routeShortName ?? "",
            routeLongName: group.routeLongName,
            routeType: group.routeType,
            routeColor: group.routeColor,
            routeTextColor: group.routeTextColor,
            headsign: group.headsign,
            scheduledSecondsSinceMidnight: nil,
        )
    }

    private func formatTimes(_ deps: [Departure]) -> String {
        let parts = deps.prefix(3).map { dep -> String in
            let m = Int(dep.effectiveDeparture.timeIntervalSinceNow / 60)
            return m <= 0 ? "Due" : "\(m)"
        }
        return parts.joined(separator: ", ") + " min"
    }

    // MARK: All routes serving this stop

    @ViewBuilder
    private func allRoutesSection(_ routes: [Route]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("All routes serving this stop").font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 56, maximum: 90), spacing: 8)],
                alignment: .leading, spacing: 8,
            ) {
                ForEach(dedupedRoutes(routes)) { route in
                    routeBadge(text: route.displayName, type: route.routeType,
                               prominent: false, shortName: route.routeShortName,
                               routeColor: route.routeColor,
                               routeTextColor: route.routeTextColor,
                               longName: route.routeLongName,
                               headsign: nil)
                }
            }
        }
    }

    /// Brisbane's train network has multiple route_ids per visible line —
    /// one per direction × through-routed combination (BRBN/BNBR/FGBR/BRFG
    /// all map to the "red family"; RPSP/SPRP/BRSP all map to Springfield).
    /// Collapse them to one pill per line, keyed by the user-facing pill
    /// label so the grid mirrors what TransLink itself publishes.
    private func dedupedRoutes(_ routes: [Route]) -> [Route] {
        var seen = Set<String>()
        var result: [Route] = []
        for r in routes {
            let isTrain = RouteStyle.isTrain(r.routeType)
            let key: String
            if isTrain {
                let pill = trainLine(longName: r.routeLongName,
                                     routeColor: r.routeColor)?.pillName
                    ?? r.routeLongName
                    ?? r.routeShortName
                    ?? r.id
                key = "train|\(pill)"
            } else {
                key = "\(r.routeType)|\(r.routeShortName ?? r.id)"
            }
            if seen.insert(key).inserted {
                result.append(r)
            }
        }
        return result
    }

    // MARK: Route badge

    private func routeBadge(
        text: String, type: Int, prominent: Bool, shortName: String?,
        routeColor: String? = nil, routeTextColor: String? = nil,
        longName: String? = nil, headsign: String? = nil,
    ) -> some View {
        let tappable = (shortName?.isEmpty == false)
        // RouteStyle.label() falls back to shortName ?? longName ?? "?" for
        // non-train routes; this badge's caller-supplied `text` (often a
        // pre-resolved displayName) is the desired fallback here, so only
        // use RouteStyle's result for trains.
        let label = RouteStyle.isTrain(type)
            ? RouteStyle.label(routeType: type, routeShortName: shortName,
                               routeLongName: longName, routeColor: routeColor,
                               headsign: headsign)
            : text
        let bg = RouteStyle.tint(routeType: type, routeColor: routeColor,
                                  routeLongName: longName, headsign: headsign)
        let fg = RouteStyle.foreground(routeType: type, routeTextColor: routeTextColor)
        return Button {
            if let s = shortName, !s.isEmpty {
                routeStopsRequest = RouteStopsRequest(shortName: s, headsign: headsign)
            }
        } label: {
            Text(label)
                .font(.system(size: prominent ? 15 : 13,
                              weight: .bold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, prominent ? 12 : 10)
                .padding(.vertical, prominent ? 7 : 5)
                .foregroundStyle(fg)
                .background(bg, in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: prominent ? 56 : 48)
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
    }

    // MARK: Loading

    @MainActor
    private func loadAll() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            async let d = TransLinkClient.shared.stopDetail(stopId: stop.stopId)
            async let deps = TransLinkClient.shared.departures(
                stopId: stop.stopId, limit: 30, windowMin: 120,
            )
            detail = try await d
            departures = try await deps
            await reconcileNextServicePeek()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// When the 2-hour window has nothing, peek up to a week ahead for the
    /// very next service so the user still sees a time/route they can rely
    /// on — even at weekday-only stops checked on a weekend.
    @MainActor
    private func reconcileNextServicePeek() async {
        guard departures.isEmpty else {
            nextServicePeek = nil
            return
        }
        do {
            let next = try await TransLinkClient.shared.departures(
                stopId: stop.stopId, limit: 1, windowMin: 10080,
            )
            nextServicePeek = next.first
        } catch {
            // Silent — fall back to the plain "No upcoming…" message.
        }
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { return }
                await refreshDepartures()
            }
        }
    }

    @MainActor
    private func refreshDepartures() async {
        do {
            departures = try await TransLinkClient.shared.departures(
                stopId: stop.stopId, limit: 30, windowMin: 120,
            )
            await reconcileNextServicePeek()
        } catch {
            // Silent — keep the last good list.
        }
    }
}

struct DepartureGroup: Identifiable {
    let key: String
    var id: String { key }
    let badge: String
    let routeShortName: String?
    let routeLongName: String?
    let routeColor: String?
    let routeTextColor: String?
    let headsign: String?
    let routeType: Int
    var times: [Departure]
}
