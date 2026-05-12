import SwiftUI

struct StopDetailView: View {
    let stopId: String
    let stopName: String

    @State private var detail: StopDetail?
    @State private var departures: [Departure] = []
    @State private var loading = false
    @State private var error: String?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section("Stop") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail?.stop.stopName ?? stopName).font(.headline)
                        if let code = detail?.stop.stopCode {
                            Text("Stop code \(code)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !departures.isEmpty {
                    Section("Next departures") {
                        ForEach(departures) { dep in
                            DepartureRow(departure: dep)
                        }
                    }
                }

                if departures.isEmpty && !loading {
                    Text("No upcoming departures in the next hour.")
                        .foregroundStyle(.secondary).font(.subheadline)
                }

                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .navigationTitle(stopName)
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if loading && departures.isEmpty {
                    ProgressView()
                }
            }
            .task {
                await loadDetail()
                startAutoRefresh()
            }
            .onDisappear { refreshTask?.cancel() }
        }
    }

    @MainActor
    private func loadDetail() async {
        loading = true; defer { loading = false }
        do {
            async let d = TransLinkClient.shared.stopDetail(stopId: stopId)
            async let deps = TransLinkClient.shared.departures(stopId: stopId)
            detail = try await d
            departures = try await deps
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
            departures = try await TransLinkClient.shared.departures(stopId: stopId)
        } catch {
            // Silent — keep last good list.
        }
    }
}

struct DepartureRow: View {
    let departure: Departure

    var body: some View {
        HStack(spacing: 12) {
            routeBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(departure.headsign ?? departure.routeLongName ?? "—")
                    .font(.subheadline).lineLimit(1)
                if let delay = departure.delaySeconds, departure.isRealtime {
                    Text(delay >= 0 ? "+\(delay / 60) min" : "\(delay / 60) min")
                        .font(.caption)
                        .foregroundStyle(delay > 60 ? .orange : .secondary)
                } else if !departure.isRealtime {
                    Text("Scheduled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            departureTime
        }
        .opacity(departure.isCancelled ? 0.4 : 1)
        .overlay(alignment: .trailing) {
            if departure.isCancelled {
                Text("Cancelled").font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private var routeBadge: some View {
        Text(departure.routeBadge)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(routeColor, in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 44)
    }

    private var routeColor: Color {
        switch RouteType(rawValue: departure.routeType) {
        case .bus: .blue
        case .rail, .subway: .yellow
        case .ferry: .cyan
        case .tram: .pink
        default: .gray
        }
    }

    private var departureTime: some View {
        let target = departure.effectiveDeparture
        let minsAway = Int(target.timeIntervalSinceNow / 60)
        return VStack(alignment: .trailing, spacing: 2) {
            if minsAway <= 0 {
                Text("Now").font(.headline).monospacedDigit()
            } else if minsAway < 60 {
                Text("\(minsAway) min").font(.headline).monospacedDigit()
            } else {
                Text(target, style: .time).font(.headline).monospacedDigit()
            }
            if departure.isRealtime {
                HStack(spacing: 3) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Live")
                }.font(.caption2).foregroundStyle(.green)
            }
        }
    }
}
