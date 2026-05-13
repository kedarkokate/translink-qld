import SwiftUI

struct StopDetailView: View {
    let stop: NearbyStop

    @State private var detail: StopDetail?
    @State private var departures: [Departure] = []
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
                        Text("No upcoming departures in the next two hours.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                RouteStopsView(shortName: req.shortName)
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stop.stopName)
                .font(.largeTitle).fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
            if let code = stop.stopCode {
                Text("Stop \(code)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Upcoming departures (grouped by route + headsign)

    private var grouped: [DepartureGroup] {
        var byKey: [String: DepartureGroup] = [:]
        var keyOrder: [String] = []
        let sorted = departures
            .filter { !$0.isCancelled }
            .sorted { $0.effectiveDeparture < $1.effectiveDeparture }
        for dep in sorted {
            let key = "\(dep.routeId)|\(dep.headsign ?? "")"
            if byKey[key] == nil {
                byKey[key] = DepartureGroup(
                    key: key, badge: dep.routeBadge,
                    routeShortName: dep.routeShortName,
                    headsign: dep.headsign, routeType: dep.routeType, times: [],
                )
                keyOrder.append(key)
            }
            byKey[key]!.times.append(dep)
        }
        return keyOrder.compactMap { byKey[$0] }
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
                       shortName: group.routeShortName)
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
        }
        .padding(.vertical, 6)
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
                ForEach(routes) { route in
                    routeBadge(text: route.displayName, type: route.routeType,
                               prominent: false, shortName: route.routeShortName)
                }
            }
        }
    }

    // MARK: Route badge

    private func routeBadge(
        text: String, type: Int, prominent: Bool, shortName: String?,
    ) -> some View {
        let tappable = (shortName?.isEmpty == false)
        return Button {
            if let s = shortName, !s.isEmpty {
                routeStopsRequest = RouteStopsRequest(shortName: s)
            }
        } label: {
            Text(text)
                .font(.system(size: prominent ? 15 : 13,
                              weight: .bold, design: .rounded))
                .padding(.horizontal, prominent ? 12 : 10)
                .padding(.vertical, prominent ? 7 : 5)
                .foregroundStyle(.white)
                .background(routeColor(type), in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: prominent ? 56 : 48)
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
    }

    private func routeColor(_ rt: Int) -> Color {
        switch RouteType(rawValue: rt) {
        case .bus: .blue
        case .rail, .subway: .indigo
        case .ferry: .cyan
        case .tram: .pink
        default: .gray
        }
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
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
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
    let headsign: String?
    let routeType: Int
    var times: [Departure]
}
