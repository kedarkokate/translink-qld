import SwiftUI

struct RouteLookupView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Show on map" with the nearest stop for their
    /// route. The parent should dismiss the sheet (this view also calls
    /// `dismiss()` itself) and update the map camera.
    let onShowOnMap: (NearbyStop, _ routeShortName: String) -> Void

    @State private var input = ""
    @State private var result: RouteNearestStop?
    @State private var searching = false
    @State private var error: String?
    @State private var routeStopsRequest: RouteStopsRequest?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                searchBar

                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                }

                if let result {
                    Divider()
                    resultCard(result)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Find by route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { inputFocused = true }
            .sheet(item: $routeStopsRequest) { req in
                RouteStopsView(shortName: req.shortName)
            }
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Route number (e.g. 66, M2, N100)", text: $input)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($inputFocused)
                    .onSubmit { Task { await search() } }
                if !input.isEmpty {
                    Button {
                        input = ""; result = nil; error = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))

            Button {
                Task { await search() }
            } label: {
                if searching {
                    ProgressView().frame(width: 22, height: 22)
                } else {
                    Text("Search").fontWeight(.semibold)
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || searching)
        }
    }

    @ViewBuilder
    private func resultCard(_ r: RouteNearestStop) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    routeStopsRequest = RouteStopsRequest(shortName: r.routeShortName)
                } label: {
                    Text(r.routeShortName)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Text("Nearest stop")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(r.nearestStop.stopName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(formattedDistance(r.nearestStop.distanceM)) away")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Button {
                onShowOnMap(r.nearestStop, r.routeShortName)
                dismiss()
            } label: {
                Label("Show on map", systemImage: "map")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func formattedDistance(_ m: Double) -> String {
        m < 1000 ? "\(Int(m)) m" : String(format: "%.1f km", m / 1000)
    }

    @MainActor
    private func search() async {
        let q = input.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        guard let loc = locationManager.lastLocation?.coordinate else {
            error = "Waiting for your location — try again in a few seconds."
            return
        }
        searching = true; error = nil; result = nil
        defer { searching = false }
        inputFocused = false
        do {
            result = try await TransLinkClient.shared.routeNearestStop(
                shortName: q, lat: loc.latitude, lon: loc.longitude,
            )
        } catch TransLinkError.http(404) {
            error = "No stops found for route “\(q)”. Double-check the number."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
