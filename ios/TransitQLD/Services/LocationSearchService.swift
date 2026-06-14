import Foundation
import MapKit
import CoreLocation
import Observation

/// Owns the as-you-type search results for the location picker. Runs two
/// concurrent searches and exposes their results separately so the UI can
/// section them: our `/v1/stops/search` for transit stops, and Apple's
/// `MKLocalSearchCompleter` for addresses + points of interest.
@MainActor
@Observable
final class LocationSearchService: NSObject, MKLocalSearchCompleterDelegate {
    var query: String = "" {
        didSet { handleQueryChange() }
    }
    var stopResults: [NearbyStop] = []
    var placeResults: [MKLocalSearchCompletion] = []
    var loading = false
    var error: String?

    let near: CLLocationCoordinate2D?
    private let completer: MKLocalSearchCompleter
    private var debounceTask: Task<Void, Never>?

    init(near: CLLocationCoordinate2D?) {
        self.near = near
        self.completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let near {
            // Constrain Apple's search to ~100 km around the user so we don't
            // suggest Sydney addresses for "Roma".
            completer.region = MKCoordinateRegion(
                center: near,
                span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0),
            )
        }
    }

    private func handleQueryChange() {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 {
            stopResults = []
            placeResults = []
            loading = false
            return
        }
        loading = true
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ q: String) async {
        completer.queryFragment = q
        do {
            stopResults = try await TransLinkClient.shared.searchStops(
                query: q, near: near, limit: 8,
            )
        } catch is CancellationError {
            return
        } catch {
            // Keep prior results visible; surface error softly
            self.error = error.localizedDescription
        }
        // `completerDidUpdateResults` / `completer(_:didFailWithError:)` also
        // clear `loading`, but the completer's delegate isn't guaranteed to
        // fire again if `queryFragment` produces the same results as last
        // time — clear it here too so the spinner never gets stuck.
        loading = false
    }

    func resolveCompletion(_ completion: MKLocalSearchCompletion) async throws -> SearchLocation {
        let request = MKLocalSearch.Request(completion: completion)
        if let near {
            request.region = MKCoordinateRegion(
                center: near,
                span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0),
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw NSError(domain: "LocationSearch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Place lookup returned no results."])
        }
        let coord = item.placemark.coordinate
        return SearchLocation(
            id: "place:\(completion.title)|\(completion.subtitle)",
            title: completion.title.isEmpty ? (item.name ?? "Place") : completion.title,
            subtitle: completion.subtitle.isEmpty ? nil : completion.subtitle,
            coordinate: coord,
            kind: .place,
        )
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor [weak self] in
            self?.placeResults = results
            self?.loading = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.error = message
            self?.loading = false
        }
    }
}
