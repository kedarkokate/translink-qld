import Foundation
import MapKit
import CoreLocation

struct TransitOption: Identifiable {
    let id = UUID()
    let totalDuration: TimeInterval
    let stepCount: Int
    let advisoryNotices: [String]
    let steps: [Step]
    let name: String

    /// Apple's MKDirections doesn't reliably expose the "number of transfers"
    /// for transit routes, but a higher step count usually correlates with
    /// more transfers. We use it as a rough secondary sort.
    var changes: Int { max(0, stepCount - 2) }

    struct Step: Identifiable {
        let id = UUID()
        let instructions: String
        let distance: CLLocationDistance
        let transportType: MKDirectionsTransportType
    }
}

@MainActor
enum TransitDirectionsService {
    /// Calls MKDirections with `.transit`. Brisbane is generally supported
    /// but the response may be sparse — Apple reserves rich transit details
    /// for the Maps app. Returns whatever it can; the UI's "Open in Apple Maps"
    /// button is the safety net.
    static func transitOptions(
        from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
    ) async throws -> [TransitOption] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .transit
        request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()

        return response.routes.map { route in
            TransitOption(
                totalDuration: route.expectedTravelTime,
                stepCount: route.steps.count,
                advisoryNotices: route.advisoryNotices,
                steps: route.steps.map { s in
                    TransitOption.Step(
                        instructions: s.instructions,
                        distance: s.distance,
                        transportType: s.transportType,
                    )
                },
                name: route.name,
            )
        }
        .sorted {
            // Fastest first; tiebreak by fewer changes.
            if $0.totalDuration != $1.totalDuration {
                return $0.totalDuration < $1.totalDuration
            }
            return $0.changes < $1.changes
        }
    }

    static func openInAppleMaps(
        from: CLLocationCoordinate2D, fromName: String,
        to: CLLocationCoordinate2D, toName: String,
    ) {
        let src = MKMapItem(placemark: MKPlacemark(coordinate: from))
        src.name = fromName
        let dst = MKMapItem(placemark: MKPlacemark(coordinate: to))
        dst.name = toName
        MKMapItem.openMaps(
            with: [src, dst],
            launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit,
            ],
        )
    }
}
