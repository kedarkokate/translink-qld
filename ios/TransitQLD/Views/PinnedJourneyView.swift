import SwiftUI

/// Detail sheet for the journey the user pinned from Directions. Shows the
/// same step-by-step breakdown as a row in the Directions result list,
/// plus an Unpin button so the user can dismiss the plan entirely.
struct PinnedJourneyView: View {
    let option: JourneyOption
    let onUnpin: () -> Void
    let onStopTap: ((NearbyStop, String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    Divider()
                    steps
                    if let delay = option.delaySeconds, abs(delay) >= 60 {
                        Text(delay > 0
                             ? "Running \(delay / 60) min late"
                             : "Running \(abs(delay) / 60) min early")
                            .font(.caption)
                            .foregroundStyle(delay > 0 ? .orange : .green)
                    }
                }
                .padding()
            }
            .navigationTitle("Pinned journey")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Unpin", systemImage: "pin.slash") { onUnpin() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        HStack(spacing: 10) {
            routeBadge(option.route, headsign: option.headsign)
            Text("\(option.totalMinutes) min")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            if option.isRealtime {
                HStack(spacing: 3) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Live")
                }
                .font(.caption2)
                .foregroundStyle(.green)
            }
        }
        if let headsign = option.headsign {
            Text("→ \(headsign)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var steps: some View {
        let leg1Route = option.route.routeShortName ?? ""
        let leg2Route = option.transfer?.route.routeShortName ?? ""

        VStack(alignment: .leading, spacing: 6) {
            step(
                icon: "figure.walk", color: .secondary,
                primary: "Walk \(option.walkToMinutes) min to \(option.board.stopName)",
                secondary: "\(option.board.walkDistanceM) m",
                onTap: onStopTap.map { handler in
                    { handler(asNearbyStop(option.board, mode: option.route.routeType), leg1Route) }
                },
            )
            step(
                icon: routeIcon(option.route.routeType),
                color: routeTint(option.route, headsign: option.headsign),
                primary: "Catch \(routeLabel(option.route, headsign: option.headsign)) at \(formatTime(option.board.effectiveTime))",
                secondary: option.transfer == nil
                    ? "Ride \(option.transitMinutes) min → arrive \(formatTime(option.alight.effectiveTime))"
                    : "Ride to \(option.alight.stopName) → arrive \(formatTime(option.alight.effectiveTime))",
                onTap: nil,
            )
            if let transfer = option.transfer {
                step(
                    icon: "arrow.triangle.swap", color: .orange,
                    primary: "Transfer at \(transfer.board.stopName)",
                    secondary: transfer.waitMinutes <= 1 ? "Cross-platform" : "Wait \(transfer.waitMinutes) min",
                    onTap: onStopTap.map { handler in
                        { handler(asNearbyStop(transfer.board, mode: transfer.route.routeType), leg2Route) }
                    },
                )
                step(
                    icon: routeIcon(transfer.route.routeType),
                    color: routeTint(transfer.route, headsign: transfer.headsign),
                    primary: "Catch \(routeLabel(transfer.route, headsign: transfer.headsign)) at \(formatTime(transfer.board.effectiveTime))",
                    secondary: "Ride to \(transfer.alight.stopName) → arrive \(formatTime(transfer.alight.effectiveTime))",
                    onTap: nil,
                )
            }
            let finalAlight = option.transfer?.alight ?? option.alight
            let finalRoute = option.transfer == nil ? leg1Route : leg2Route
            let finalMode = option.transfer?.route.routeType ?? option.route.routeType
            step(
                icon: "figure.walk", color: .secondary,
                primary: "Walk \(option.walkFromMinutes) min from \(finalAlight.stopName)",
                secondary: "\(finalAlight.walkDistanceM) m",
                onTap: onStopTap.map { handler in
                    { handler(asNearbyStop(finalAlight, mode: finalMode), finalRoute) }
                },
            )
        }
    }

    private func step(
        icon: String, color: Color,
        primary: String, secondary: String,
        onTap: (() -> Void)?,
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private func routeBadge(_ route: JourneyRoute, headsign: String?) -> some View {
        Text(route.routeShortName ?? route.routeLongName ?? "?")
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(Color(gtfsHex: route.routeTextColor) ?? .white)
            .background(routeTint(route, headsign: headsign), in: RoundedRectangle(cornerRadius: 6))
    }

    private func routeIcon(_ routeType: Int) -> String {
        switch routeType {
        case 2: return "tram.fill"
        case 4: return "ferry.fill"
        default: return "bus.fill"
        }
    }

    private func routeTint(_ route: JourneyRoute, headsign: String?) -> Color {
        Color(gtfsHex: route.routeColor) ?? .blue
    }

    private func routeLabel(_ route: JourneyRoute, headsign: String?) -> String {
        route.routeShortName ?? route.routeLongName ?? "?"
    }

    private func formatTime(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    private func asNearbyStop(_ ref: JourneyStopRef, mode: Int) -> NearbyStop {
        NearbyStop(
            stopId: ref.stopId,
            stopCode: nil,
            stopName: ref.stopName,
            stopLat: ref.stopLat,
            stopLon: ref.stopLon,
            locationType: 0,
            parentStation: nil,
            platformCode: nil,
            routeTypes: "\(mode)",
            distanceM: Double(ref.walkDistanceM),
        )
    }
}
