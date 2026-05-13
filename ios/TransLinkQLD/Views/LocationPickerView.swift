import SwiftUI
import MapKit
import CoreLocation

struct LocationPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let near: CLLocationCoordinate2D?
    let allowCurrentLocation: Bool
    let title: String
    let onPick: (SearchLocation) -> Void

    @State private var service: LocationSearchService
    @State private var query = ""
    @State private var resolving = false
    @State private var resolveError: String?

    init(
        near: CLLocationCoordinate2D?,
        allowCurrentLocation: Bool,
        title: String,
        onPick: @escaping (SearchLocation) -> Void,
    ) {
        self.near = near
        self.allowCurrentLocation = allowCurrentLocation
        self.title = title
        self.onPick = onPick
        _service = State(initialValue: LocationSearchService(near: near))
    }

    var body: some View {
        NavigationStack {
            List {
                if allowCurrentLocation, let near {
                    Section {
                        pickButton {
                            onPick(.currentLocation(near))
                            dismiss()
                        } label: {
                            row(icon: "location.fill", tint: .blue,
                                title: "Current Location", subtitle: nil)
                        }
                    }
                }

                if !service.stopResults.isEmpty {
                    Section("Stops") {
                        ForEach(service.stopResults) { stop in
                            pickButton {
                                onPick(SearchLocation.from(stop: stop))
                                dismiss()
                            } label: {
                                row(
                                    icon: stop.isFerry ? "ferry.fill" : "bus.fill",
                                    tint: stop.isFerry ? .blue : .red,
                                    title: stop.stopName,
                                    subtitle: stop.stopCode.map { "Stop \($0)" },
                                )
                            }
                        }
                    }
                }

                if !service.placeResults.isEmpty {
                    Section("Places") {
                        ForEach(service.placeResults, id: \.self) { completion in
                            pickButton {
                                Task { await resolveAndPick(completion) }
                            } label: {
                                row(
                                    icon: "mappin.circle.fill",
                                    tint: .orange,
                                    title: completion.title,
                                    subtitle: completion.subtitle.isEmpty
                                        ? nil : completion.subtitle,
                                )
                            }
                        }
                    }
                }

                if service.loading || resolving {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(resolving ? "Resolving…" : "Searching…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let resolveError {
                    Text(resolveError).foregroundStyle(.red).font(.caption)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search stops, addresses, places")
            .onChange(of: query) { _, new in service.query = new }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func pickButton<Label: View>(
        action: @escaping () -> Void, @ViewBuilder label: () -> Label,
    ) -> some View {
        Button(action: action, label: label).buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @MainActor
    private func resolveAndPick(_ completion: MKLocalSearchCompletion) async {
        resolving = true; resolveError = nil
        defer { resolving = false }
        do {
            let loc = try await service.resolveCompletion(completion)
            onPick(loc)
            dismiss()
        } catch {
            resolveError = error.localizedDescription
        }
    }
}
