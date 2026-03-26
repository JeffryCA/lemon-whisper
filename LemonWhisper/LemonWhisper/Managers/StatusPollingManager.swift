import Foundation

@MainActor
final class StatusPollingManager {
    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    func start(interval: TimeInterval = 2.0, onTick: @escaping @MainActor () -> Void) {
        stop()
        onTick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                onTick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
