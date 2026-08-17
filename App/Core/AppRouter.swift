import Foundation
import Observation

/// Where the app should be showing right now.
///
/// `LiveActivityIntent.perform()` runs in the app's own process, so the Daily Review button on an
/// alarm can set a route here directly. That is what removes the need for an App Group — which in
/// turn is what lets this build and sign under a free Apple ID.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Route: Equatable {
        case chat
        case dailyReview(dayKey: String)
        case upcoming
        case occurrence(UUID)
    }

    var route: Route = .chat
    /// Set by an intent that fired while the app was not on screen. The chat view drains it when
    /// it next becomes active.
    var pendingRoute: Route?

    private init() {}

    func request(_ route: Route) {
        pendingRoute = route
    }

    func drainPendingRoute() {
        guard let pending = pendingRoute else { return }
        route = pending
        pendingRoute = nil
    }
}
