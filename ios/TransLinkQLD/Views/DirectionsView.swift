import SwiftUI
import MapKit
import CoreLocation

struct DirectionsView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var from: SearchLocation?
    @State private var to: SearchLocation?
    @State private var pickerKind: PickerKind?
    @State private var options: [JourneyOption] = []
    @State private var searching = false
    @State private var error: String?
    @State private var routeStopsRequest: RouteStopsRequest?

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
            .padding(.vertical, 12)
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if from == nil, let loc = locationManager.lastLocation?.coordinate {
                    from = .currentLocation(loc)
                }
            }
            .sheet(item: $routeStopsRequest) { req in
                RouteStopsView(shortName: req.shortName)
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
                    Label("Open in Apple Maps for full directions",
                          systemImage: "map")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func optionRow(_ option: JourneyOption, isBest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                routeBadge(option.route)
                Text("\(option.totalMinutes) min")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                if option.isRealtime {
                    HStack(spacing: 3) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("Live")
                    }
                    .font(.caption2)
                    .foregroundStyle(.green)
                }
                Spacer()
                if isBest {
                    Text("Best")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(.green, in: Capsule())
                }
            }

            if let headsign = option.headsign {
                Text("→ \(headsign)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                journeyStep(
                    icon: "figure.walk", iconColor: .secondary,
                    primary: "Walk \(option.walkToMinutes) min to \(option.board.stopName)",
                    secondary: "\(option.board.walkDistanceM) m",
                )
                journeyStep(
                    icon: routeIcon(option.route.routeType),
                    iconColor: routeColor(option.route.routeType),
                    primary: "Catch \(option.route.displayName) at \(formatTime(option.board.effectiveTime))",
                    secondary: "Ride \(option.transitMinutes) min → arrive \(formatTime(option.alight.effectiveTime))",
                )
                journeyStep(
                    icon: "figure.walk", iconColor: .secondary,
                    primary: "Walk \(option.walkFromMinutes) min from \(option.alight.stopName)",
                    secondary: "\(option.alight.walkDistanceM) m",
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

    private func journeyStep(
        icon: String, iconColor: Color,
        primary: String, secondary: String,
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(primary).font(.subheadline)
                Text(secondary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func routeBadge(_ route: JourneyRoute) -> some View {
        Button {
            if let name = route.routeShortName, !name.isEmpty {
                routeStopsRequest = RouteStopsRequest(shortName: name)
            }
        } label: {
            HStack(spacing: 4) {
                Text(route.displayName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                if route.routeShortName?.isEmpty == false {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(routeColor(route.routeType), in: RoundedRectangle(cornerRadius: 8))
            .frame(minWidth: 48)
        }
        .buttonStyle(.plain)
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

    private func formatTime(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt.string(from: d)
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

    private let noRoutesMessage = """
    No direct transit routes were found within ~500 m walking distance and \
    the next 90 minutes.

    This version only finds single-trip journeys (no transfers). For longer \
    or transfer-needing trips, open Apple Maps below.
    """

    private func openInAppleMaps() {
        guard let f = from, let t = to else { return }
        TransitDirectionsService.openInAppleMaps(
            from: f.coordinate, fromName: f.title,
            to: t.coordinate, toName: t.title,
        )
    }

}
