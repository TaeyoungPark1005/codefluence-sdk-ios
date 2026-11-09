import Foundation
#if canImport(Network)
import Network
#endif

/// Deterministic exponential backoff with full jitter and a hard cap (A3).
///
/// `delay(forAttempt:)` returns the delay to wait *before* the given 1-based
/// attempt number. Attempt 1 is immediate (0). The base grows by `factor` and is
/// clamped to `cap`; jitter is applied in `[0, computed]` using the injected
/// random source so tests can assert exact bounds.
public struct CodefluenceBackoffPolicy {
    public let base: TimeInterval
    public let factor: Double
    public let cap: TimeInterval
    public let maxAttempts: Int

    public init(base: TimeInterval = 2, factor: Double = 2, cap: TimeInterval = 3600, maxAttempts: Int = 10) {
        self.base = base
        self.factor = factor
        self.cap = cap
        self.maxAttempts = maxAttempts
    }

    /// Unjittered ceiling for the wait before `attempt` (1-based). Attempt 1 → 0.
    public func ceiling(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let exponent = Double(attempt - 2)
        let raw = base * pow(factor, exponent)
        return min(raw, cap)
    }

    /// Jittered delay in `[0, ceiling]`. `jitter` is a value in `[0, 1)`.
    public func delay(forAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let bounded = max(0, min(jitter, 0.999999))
        return ceiling(forAttempt: attempt) * bounded
    }

    /// Whether another automatic attempt is allowed. `completedAttempts` is the
    /// number already sent; the queue stops once it reaches `maxAttempts`.
    public func canAttempt(afterCompleted completedAttempts: Int) -> Bool {
        completedAttempts < maxAttempts
    }
}

/// HTTP/transport classification for retry decisions (A3).
enum ConfirmationFailureClass {
    case permanent // 400/401/403/404/409/422 — never retry.
    case retryable // 408/429/5xx/transport error — retry with backoff.

    /// Classifies an HTTP status. 2xx is handled as success by the caller.
    static func forStatus(_ status: Int) -> ConfirmationFailureClass {
        switch status {
        case 400, 401, 403, 404, 409, 422: return .permanent
        case 408, 429: return .retryable
        case 500...599: return .retryable
        default:
            // Other 4xx are treated as permanent (do not loop on malformed input);
            // anything below 400 that is not success is unexpected and permanent.
            return status >= 400 && status < 500 ? .permanent : .retryable
        }
    }
}

/// Network reachability signal, injectable for tests (A3). The default uses
/// `NWPathMonitor` to drive automatic retries when connectivity returns.
public protocol CodefluenceNetworkMonitor {
    /// Starts monitoring; `onSatisfied` is called whenever the path becomes
    /// satisfied (reachable), including recoveries after an outage.
    func start(onSatisfied: @escaping () -> Void)
    func cancel()
}

#if canImport(Network)
final class SystemNetworkMonitor: CodefluenceNetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "codefluence.network-monitor")
    private var wasSatisfied = false

    func start(onSatisfied: @escaping () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            // Fire on first satisfied state and on every recovery edge.
            let shouldFire = satisfied && !self.wasSatisfied
            self.wasSatisfied = satisfied
            if shouldFire { onSatisfied() }
        }
        monitor.start(queue: queue)
    }

    func cancel() { monitor.cancel() }
}
#endif
