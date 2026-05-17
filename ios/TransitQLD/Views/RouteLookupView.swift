import SwiftUI

struct RouteLookupView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Show on map" with the nearest stop for their
    /// route. The parent should dismiss the sheet (this view also calls
    /// `dismiss()` itself) and update the map camera.
    let onShowOnMap: (NearbyStop, _ routeShortName: String) -> Void

    // Route-number search state
    @State private var input = ""
    @State private var result: RouteNearestStop?
    @State private var searching = false
    @State private var error: String?

    // School-routes section state
    @AppStorage("school_routes_radius_m") private var schoolRadiusM: Int = 1000
    @State private var schoolMatches: [SchoolRouteMatch] = []
    @State private var searchingSchools = false
    @State private var schoolError: String?
    @State private var didSearchSchools = false

    @State private var routeStopsRequest: RouteStopsRequest?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchBar
                    if let error {
                        Text(error).font(.subheadline).foregroundStyle(.red)
                    }
                    if let result {
                        Divider()
                        resultCard(result)
                    }

                    Divider().padding(.top, 4)
                    schoolRoutesSection
                }
                .padding()
            }
            .navigationTitle("Find by route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { inputFocused = true }
            .sheet(item: $routeStopsRequest) { req in
                RouteStopsView(shortName: req.shortName, selectedHeadsign: req.headsign)
            }
        }
    }

    // MARK: Route-number search

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

    // MARK: School routes

    @ViewBuilder
    private var schoolRoutesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill").foregroundStyle(.indigo)
                Text("School routes near me").font(.headline)
            }

            HStack(spacing: 8) {
                Text("Within").font(.subheadline).foregroundStyle(.secondary)
                Picker("Radius", selection: $schoolRadiusM) {
                    Text("500 m").tag(500)
                    Text("1 km").tag(1000)
                    Text("2 km").tag(2000)
                    Text("5 km").tag(5000)
                }
                .pickerStyle(.segmented)
            }

            Button {
                Task { await searchSchools() }
            } label: {
                Group {
                    if searchingSchools {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Searching nearby…")
                        }
                    } else {
                        Label("Find school routes",
                              systemImage: "location.magnifyingglass")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(searchingSchools)

            if let schoolError {
                Text(schoolError).font(.subheadline).foregroundStyle(.red)
            }

            if !schoolMatches.isEmpty {
                VStack(spacing: 8) {
                    ForEach(schoolMatches) { match in
                        schoolMatchRow(match)
                    }
                }
            } else if didSearchSchools && !searchingSchools {
                Text("No school routes within \(formattedDistance(Double(schoolRadiusM))).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func schoolMatchRow(_ match: SchoolRouteMatch) -> some View {
        Button {
            routeStopsRequest = RouteStopsRequest(shortName: match.routeShortName)
        } label: {
            HStack(spacing: 12) {
                Text(match.routeShortName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(.white)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 8))
                    .frame(minWidth: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.schoolHeadsign)
                        .font(.subheadline).lineLimit(1)
                    Text("\(formattedDistance(match.nearestStop.distanceM)) · \(match.nearestStop.stopName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

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

    @MainActor
    private func searchSchools() async {
        guard let loc = locationManager.lastLocation?.coordinate else {
            schoolError = "Waiting for your location — try again in a few seconds."
            return
        }
        searchingSchools = true; schoolError = nil; schoolMatches = []
        defer { searchingSchools = false }
        inputFocused = false
        do {
            schoolMatches = try await TransLinkClient.shared.schoolRoutesNear(
                lat: loc.latitude, lon: loc.longitude,
                radiusM: schoolRadiusM,
            )
            didSearchSchools = true
        } catch {
            self.schoolError = error.localizedDescription
        }
    }
}
