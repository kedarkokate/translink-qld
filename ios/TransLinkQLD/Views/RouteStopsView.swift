import SwiftUI

/// Lightweight identifiable wrapper so `.sheet(item:)` can present this view
/// for a given route short name (`"61"`, `"M2"`, ...).
struct RouteStopsRequest: Identifiable, Hashable {
    let shortName: String
    var id: String { shortName }
}

struct RouteStopsView: View {
    let shortName: String
    @Environment(\.dismiss) private var dismiss

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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
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
                        Text(r.routeShortName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(routeColor(r.routeType),
                                        in: RoundedRectangle(cornerRadius: 8))
                        Text(longName)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(r.directions) { dir in
                Section(header: directionHeader(dir, type: r.routeType)) {
                    ForEach(dir.stops) { stop in
                        Button {
                            selectedStop = stop.asNearbyStop()
                        } label: {
                            stopRow(stop)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func directionHeader(_ dir: RouteDirection, type: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: routeIcon(type))
                .foregroundStyle(routeColor(type))
            Text("Towards \(dir.headsign ?? "—")")
                .font(.subheadline.weight(.semibold))
                .textCase(nil)
        }
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

    private func routeColor(_ rt: Int) -> Color {
        switch RouteType(rawValue: rt) {
        case .bus: return .blue
        case .rail, .subway: return .indigo
        case .ferry: return .cyan
        case .tram: return .pink
        default: return .gray
        }
    }

    private func routeIcon(_ rt: Int) -> String {
        switch RouteType(rawValue: rt) {
        case .bus: return "bus.fill"
        case .rail, .subway: return "train.side.front.car"
        case .ferry: return "ferry.fill"
        case .tram: return "tram.fill"
        default: return "bus.fill"
        }
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
