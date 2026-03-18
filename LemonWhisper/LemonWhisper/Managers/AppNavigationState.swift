import SwiftUI

enum AppRoute: Hashable {
    case manageModels
    case transcriptions
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published private(set) var currentRoute: AppRoute?

    func show(_ route: AppRoute) {
        if currentRoute == route {
            return
        }
        currentRoute = route
    }

    func goHome() {
        currentRoute = nil
    }
}
