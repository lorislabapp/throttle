import Foundation
import OSLog

/// Once an hour, run a full re-scan to catch anything FSEvents missed.
final class HourlySweeper: @unchecked Sendable {
    private let action: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "HourlySweeper")
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.lorislab.throttle.sweeper", qos: .utility)

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 3600, repeating: 3600)
            timer.setEventHandler { [weak self] in
                self?.logger.info("Running hourly sweep")
                self?.action()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }
}
