import SwiftUI

struct RouteLookupView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(FavouritesStore.self) private var favourites
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
    @AppStorage("school_routes_expanded_v1") private var schoolRoutesExpanded: Bool = false
    @State private var schoolMatches: [SchoolRouteMatch] = []
    @State private var searchingSchools = false
    @State private var schoolError: String?
    @State private var didSearchSchools = false

    // Train-lines section: collapsed by default; persisted per-user so a
    // regular train rider doesn't have to re-expand it on every visit.
    @AppStorage("train_lines_expanded_v1") private var trainLinesExpanded: Bool = false

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
                    trainLinesSection

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
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Close")
                }
                // System .numberPad has no Return key, so without this the
                // user has to reach all the way back up to the Search button
                // next to the input. The keyboard accessory keeps Search
                // one tap away from the digits they just typed.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        inputFocused = false
                        Task { await search() }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || searching)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Route number (e.g. 66, M2, N100)", text: $input)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        // Routes the user actually types are either pure-numeric
                        // (200, 411, 192…) or one of three letter-prefix
                        // families: F (ferry), M (Metro), N (NightLink). The
                        // full QWERTY keyboard was overkill; the numberPad
                        // plus the inline prefix chips below the bar covers
                        // >99% of inputs. Train lines have their own section.
                        .keyboardType(.numberPad)
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
            // Letter-prefix chips sit immediately under the search bar so
            // they're always next to where the user is typing, not stranded
            // at the bottom of the screen above the keyboard.
            HStack(spacing: 8) {
                prefixChip("F")
                prefixChip("M")
                prefixChip("N")
                Spacer()
            }
        }
    }

    private func prefixChip(_ letter: String) -> some View {
        let isActive = input.uppercased().hasPrefix(letter)
        return Button { setPrefix(letter) } label: {
            Text(letter)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 32)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : .secondary)
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
                Spacer()
                routeAtStopFavToggle(
                    route: r.routeShortName,
                    routeLongName: nil, routeType: 3,
                    routeColor: nil, routeTextColor: nil,
                    headsign: nil,
                    stop: r.nearestStop,
                )
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

    /// Shared trailing-edge star button used by both the route-search result
    /// card and the school-route rows. Bookmarks "this route at this stop"
    /// using the same matchKey shape as the StopDetailView star, so all
    /// three paths dedupe naturally.
    @ViewBuilder
    private func routeAtStopFavToggle(
        route: String, routeLongName: String?, routeType: Int,
        routeColor: String?, routeTextColor: String?,
        headsign: String?, stop: NearbyStop,
    ) -> some View {
        let existing = favourites.service(
            matching: stop.stopId, route: route,
            headsign: headsign, secondsSinceMidnight: nil,
        )
        let isFav = existing != nil
        Button {
            if let fav = existing {
                favourites.removeService(id: fav.id)
            } else {
                favourites.addService(FavouriteService(
                    stopId: stop.stopId, stopName: stop.stopName,
                    stopCode: stop.stopCode,
                    stopLat: stop.stopLat, stopLon: stop.stopLon,
                    routeTypes: stop.routeTypes,
                    routeShortName: route, routeLongName: routeLongName,
                    routeType: routeType,
                    routeColor: routeColor, routeTextColor: routeTextColor,
                    headsign: headsign,
                    scheduledSecondsSinceMidnight: nil,
                ))
            }
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.system(size: 17))
                .foregroundStyle(isFav ? .yellow : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFav ? "Remove favourite" : "Favourite route \(route) at this stop")
    }

    // MARK: School routes

    /// School routes lives behind a disclosure so the Route sheet opens
    // MARK: Train lines

    /// SEQ rail lines as recognisable by users — by line name with brand
    /// colour, not the GTFS internal codes (BRBN, CLBR, …). Tapping a line
    /// opens RouteStopsView with the canonical outbound (Brisbane → terminus)
    /// short_name so the rider sees stops in the typical direction first.
    private struct TrainLineEntry: Identifiable {
        let id: String         // canonical route_short_name we drill into
        let name: String       // user-facing line name
        let hex: String        // brand colour
    }

    private static let trainLines: [TrainLineEntry] = [
        .init(id: "BRBN", name: "Beenleigh line",            hex: "E31837"),
        .init(id: "BRFG", name: "Ferny Grove line",          hex: "E31837"),
        .init(id: "BRCA", name: "Caboolture line",           hex: "008752"),
        .init(id: "BRIP", name: "Ipswich line",              hex: "008752"),
        .init(id: "BRGY", name: "Sunshine Coast line",       hex: "008752"),
        .init(id: "BRRP", name: "Redcliffe Peninsula line",  hex: "1578BE"),
        .init(id: "BRSP", name: "Springfield line",          hex: "1578BE"),
        .init(id: "BRCL", name: "Cleveland line",            hex: "00467F"),
        .init(id: "BRSH", name: "Shorncliffe line",          hex: "00447C"),
        .init(id: "BRBD", name: "Airport line",              hex: "FFC425"),
        .init(id: "BRVL", name: "Gold Coast line",           hex: "FFC425"),
        .init(id: "BRDB", name: "Doomben line",              hex: "A54399"),
    ]

    @ViewBuilder
    private var trainLinesSection: some View {
        DisclosureGroup(isExpanded: $trainLinesExpanded) {
            VStack(spacing: 6) {
                ForEach(Self.trainLines) { line in
                    Button {
                        routeStopsRequest = RouteStopsRequest(shortName: line.id)
                    } label: {
                        HStack(spacing: 12) {
                            // Brand colour stripe — a vertical pill on the
                            // leading edge, like the line bar on a transit
                            // platform sign.
                            Capsule()
                                .fill(Color(gtfsHex: line.hex) ?? .gray)
                                .frame(width: 6, height: 22)
                            Text(line.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tram.fill").foregroundStyle(.indigo)
                Text("Train lines").font(.headline)
            }
        }
    }

    /// focused on the route-number search. Persists expanded/collapsed
    /// state so a user who wants school routes daily doesn't have to
    /// re-tap every time.
    @ViewBuilder
    private var schoolRoutesSection: some View {
        DisclosureGroup(isExpanded: $schoolRoutesExpanded) {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill").foregroundStyle(.indigo)
                Text("School routes near me").font(.headline)
            }
        }
    }

    @ViewBuilder
    private func schoolMatchRow(_ match: SchoolRouteMatch) -> some View {
        HStack(spacing: 8) {
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
                        if let next = match.nextDeparture {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                Text("Next: \(formatNextDeparture(next))")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.indigo)
                        }
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

            routeAtStopFavToggle(
                route: match.routeShortName,
                routeLongName: match.routeLongName,
                routeType: match.routeType,
                routeColor: nil, routeTextColor: nil,
                headsign: match.schoolHeadsign,
                stop: match.nearestStop,
            )
        }
    }

    // MARK: Helpers

    /// Replaces the input's letter prefix with the given letter, preserving
    /// any digits the user already typed. So "411" + tap M → "M411",
    /// and "M2" + tap F → "F2".
    private func setPrefix(_ letter: String) {
        let digits = input.filter { $0.isNumber }
        input = letter + digits
    }

    /// Formats the next-service timestamp relative to "now":
    ///   - Today  → "08:13 (in 23 min)" or "08:13"
    ///   - Tomorrow → "Tomorrow, 08:13"
    ///   - Same week  → "Fri, 08:13"
    ///   - Further → "Mon 25 May, 08:13"
    private func formatNextDeparture(_ d: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) {
            let mins = Int(d.timeIntervalSince(now) / 60)
            if mins <= 0 { return "\(time) (now)" }
            if mins <= 60 { return "\(time) (in \(mins) min)" }
            return time
        }
        if cal.isDateInTomorrow(d) { return "Tomorrow, \(time)" }
        let daysAhead = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                           to: cal.startOfDay(for: d)).day ?? 0
        if daysAhead < 7 {
            let weekday = d.formatted(.dateTime.weekday(.abbreviated))
            return "\(weekday), \(time)"
        }
        let dayAndDate = d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(dayAndDate), \(time)"
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
