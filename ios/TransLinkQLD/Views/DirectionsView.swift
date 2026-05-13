import SwiftUI
import MapKit
import CoreLocation

struct DirectionsView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var from: SearchLocation?
    @State private var to: SearchLocation?
    @State private var pickerKind: PickerKind?
    @State private var options: [TransitOption] = []
    @State private var searching = false
    @State private var error: String?

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
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if from != nil && to != nil {
                Button {
                    openInAppleMaps()
                } label: {
                    Label("Open in Apple Maps", systemImage: "map")
                }
                .buttonStyle(.borderedProminent)
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
    private func optionRow(_ option: TransitOption, isBest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formattedDuration(option.totalDuration))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if isBest {
                    Text("Best")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(.green, in: Capsule())
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                Text(option.changes == 0
                     ? "No changes"
                     : "\(option.changes) change\(option.changes == 1 ? "" : "s")")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            if !option.advisoryNotices.isEmpty {
                ForEach(option.advisoryNotices, id: \.self) { notice in
                    Text(notice).font(.caption2).foregroundStyle(.orange)
                }
            }

            if !option.steps.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(option.steps.prefix(4)) { step in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: stepIcon(step.transportType))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(step.instructions.isEmpty
                             ? "Continue \(Int(step.distance)) m"
                             : step.instructions)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if option.steps.count > 4 {
                    Text("…and \(option.steps.count - 4) more steps")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stepIcon(_ type: MKDirectionsTransportType) -> String {
        switch type {
        case .walking: "figure.walk"
        case .transit: "bus.fill"
        case .automobile: "car.fill"
        default: "arrow.right"
        }
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
            let results = try await TransitDirectionsService.transitOptions(
                from: f.coordinate, to: t.coordinate,
            )
            if results.isEmpty {
                error = "Apple Maps didn't return any transit routes for this trip. Try opening in Apple Maps for full step-by-step directions."
            } else {
                options = results
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openInAppleMaps() {
        guard let f = from, let t = to else { return }
        TransitDirectionsService.openInAppleMaps(
            from: f.coordinate, fromName: f.title,
            to: t.coordinate, toName: t.title,
        )
    }

    private func formattedDuration(_ secs: TimeInterval) -> String {
        let m = Int(secs / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
}
