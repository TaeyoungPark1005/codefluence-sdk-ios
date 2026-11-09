import XCTest
import Foundation
@testable import Codefluence

/// Deterministic scheduler/monitor fakes for A3 tests.
private final class ManualScheduler {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    var recordedDelays: [TimeInterval] = []
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        lock.lock(); recordedDelays.append(delay); pending.append(work); lock.unlock()
    }
    func runNext() {
        lock.lock(); let work = pending.isEmpty ? nil : pending.removeFirst(); lock.unlock()
        work?()
    }
    var scheduledCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
}

private final class TriggerableMonitor: CodefluenceNetworkMonitor {
    private var handler: (() -> Void)?
    func start(onSatisfied: @escaping () -> Void) { handler = onSatisfied }
    func cancel() { handler = nil }
    func fireSatisfied() { handler?() }
}

private final class RetryMockProtocol: URLProtocol {
    struct Captured { let idempotencyKey: String?; let body: Data }
    private static let lock = NSLock()
    private static var captured: [Captured] = []
    static var reply: (Int) -> (Int, String) = { _ in (200, "{\"leadId\":\"lead-fixture\"}") }
    static var requests: [Captured] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured = []; lock.unlock(); reply = { _ in (200, "{\"leadId\":\"lead-fixture\"}") } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(Captured(idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"), body: request.httpBody ?? Data()))
        let (status, text) = Self.reply(Self.captured.count)
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class AutomaticRetryTests: XCTestCase {
    private var suite: String!
    private var preferences: UserDefaults!
    private var session: URLSession!
    private var scheduler: ManualScheduler!
    private var monitor: TriggerableMonitor!
    private var sdk: Codefluence!

    override func setUp() {
        suite = "codefluence-retry-tests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetryMockProtocol.self]
        session = URLSession(configuration: config)
        scheduler = ManualScheduler()
        monitor = TriggerableMonitor()
        RetryMockProtocol.reset()
        sdk = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session)
        sdk.injectRetryDependencies(policy: CodefluenceBackoffPolicy(base: 2, factor: 2, cap: 3600, maxAttempts: 5),
                                    jitter: { 0.5 },
                                    scheduler: { [weak self] delay, work in self?.scheduler.schedule(delay, work) },
                                    monitor: monitor)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        preferences.removePersistentDomain(forName: suite)
        sdk = nil; session = nil; preferences = nil; scheduler = nil; monitor = nil
    }

    func testBackoffCeilingRespectsBaseFactorAndCap() {
        let policy = CodefluenceBackoffPolicy(base: 2, factor: 2, cap: 3600, maxAttempts: 10)
        XCTAssertEqual(policy.ceiling(forAttempt: 1), 0)
        XCTAssertEqual(policy.ceiling(forAttempt: 2), 2)
        XCTAssertEqual(policy.ceiling(forAttempt: 3), 4)
        XCTAssertEqual(policy.ceiling(forAttempt: 4), 8)
        // Grows geometrically but never exceeds the cap.
        XCTAssertEqual(policy.ceiling(forAttempt: 40), 3600)
    }

    func testBackoffJitterStaysWithinZeroAndCeiling() {
        let policy = CodefluenceBackoffPolicy(base: 2, factor: 2, cap: 3600, maxAttempts: 10)
        for jitter in stride(from: 0.0, through: 0.99, by: 0.07) {
            let delay = policy.delay(forAttempt: 4, jitter: jitter)
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, policy.ceiling(forAttempt: 4))
        }
    }

    func testFailureClassificationMatchesServerContract() {
        for status in [400, 401, 403, 404, 409, 422] {
            XCTAssertEqual(ConfirmationFailureClass.forStatus(status), .permanent, "\(status)")
        }
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(ConfirmationFailureClass.forStatus(status), .retryable, "\(status)")
        }
    }

    func testTransientFailureSchedulesBackoffAndReusesSameIdempotencyKey() {
        RetryMockProtocol.reply = { count in count == 1 ? (503, "{}") : (200, "{\"leadId\":\"lead-fixture\"}") }
        let failed = expectation(description: "first attempt fails")
        sdk.confirm(clickToken: "signed.token", appUserId: "customer") { result in
            if case .success = result { XCTFail("503 should not succeed") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
        // A backoff retry was scheduled for the second (1-based) attempt: ceiling 2 * 0.5 jitter.
        XCTAssertEqual(scheduler.recordedDelays.last, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)
        scheduler.runNext()
        // Wait for the async request to be captured.
        let expectation2 = expectation(description: "second attempt sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation2.fulfill() }
        wait(for: [expectation2], timeout: 2)
        let requests = RetryMockProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(requests[0].idempotencyKey)
        XCTAssertEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
        XCTAssertEqual(requests[0].body, requests[1].body)
        XCTAssertEqual(preferences.string(forKey: "codefluence.confirmedLeadId"), "lead-fixture")
    }

    func testPermanentFailureClearsQueueAndDoesNotRetry() {
        RetryMockProtocol.reply = { _ in (422, "{\"error\":\"invalid\"}") }
        let failed = expectation(description: "permanent failure")
        sdk.confirm(clickToken: "signed.token", appUserId: "customer") { result in
            if case .success = result { XCTFail("422 should not succeed") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertNil(preferences.string(forKey: "codefluence.pendingToken"))
        XCTAssertNil(preferences.string(forKey: "codefluence.pendingIdempotencyKey"))
        // A later resume finds no pending queue and sends nothing more.
        sdk.resumePendingConfirmationIfNeeded()
        XCTAssertEqual(RetryMockProtocol.requests.count, 1)
    }

    func testRelaunchResumesAcceptedPendingConfirmation() {
        // Simulate an accepted-but-unfinished confirmation left by a prior launch.
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(true, forKey: "codefluence.accepted")
        preferences.set("signed.token", forKey: "codefluence.pendingToken")
        preferences.set("customer", forKey: "codefluence.pendingAppUserId")
        preferences.set("persisted-key", forKey: "codefluence.pendingIdempotencyKey")
        preferences.set(1, forKey: "codefluence.pendingAttempts")
        sdk.resumePendingConfirmationIfNeeded()
        let done = expectation(description: "resend on relaunch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(RetryMockProtocol.requests.count, 1)
        XCTAssertEqual(RetryMockProtocol.requests.first?.idempotencyKey, "persisted-key")
        XCTAssertEqual(preferences.string(forKey: "codefluence.confirmedLeadId"), "lead-fixture")
    }

    func testNetworkRecoveryTriggersResend() {
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(true, forKey: "codefluence.accepted")
        preferences.set("signed.token", forKey: "codefluence.pendingToken")
        preferences.set("customer", forKey: "codefluence.pendingAppUserId")
        preferences.set("recovery-key", forKey: "codefluence.pendingIdempotencyKey")
        preferences.set(2, forKey: "codefluence.pendingAttempts")
        // Start monitoring, then simulate connectivity returning.
        monitor.start { [weak sdk] in sdk?.resumePendingConfirmationIfNeeded() }
        monitor.fireSatisfied()
        let done = expectation(description: "resend on recovery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(RetryMockProtocol.requests.count, 1)
        XCTAssertEqual(RetryMockProtocol.requests.first?.idempotencyKey, "recovery-key")
    }

    func testDeclinedCompletedAndNoAttributionAreNotResent() {
        // Declined.
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(false, forKey: "codefluence.accepted")
        sdk.resumePendingConfirmationIfNeeded()
        // Completed.
        preferences.removePersistentDomain(forName: suite)
        preferences.set(true, forKey: "codefluence.accepted")
        preferences.set("lead-done", forKey: "codefluence.confirmedLeadId")
        preferences.set("signed.token", forKey: "codefluence.pendingToken")
        preferences.set("customer", forKey: "codefluence.pendingAppUserId")
        sdk.resumePendingConfirmationIfNeeded()
        // No-attribution.
        preferences.removePersistentDomain(forName: suite)
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(false, forKey: "codefluence.accepted")
        sdk.resumePendingConfirmationIfNeeded()
        let done = expectation(description: "no network for terminal states")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(RetryMockProtocol.requests.isEmpty)
    }

    func testMaxAttemptsCapStopsAutomaticResend() {
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(true, forKey: "codefluence.accepted")
        preferences.set("signed.token", forKey: "codefluence.pendingToken")
        preferences.set("customer", forKey: "codefluence.pendingAppUserId")
        preferences.set("capped-key", forKey: "codefluence.pendingIdempotencyKey")
        preferences.set(5, forKey: "codefluence.pendingAttempts") // == maxAttempts
        sdk.resumePendingConfirmationIfNeeded()
        let done = expectation(description: "cap blocks resend")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(RetryMockProtocol.requests.isEmpty)
    }

    func testManualRetryResetsBackoffAttempts() {
        RetryMockProtocol.reply = { _ in (200, "{\"leadId\":\"lead-fixture\"}") }
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(true, forKey: "codefluence.accepted")
        preferences.set("signed.token", forKey: "codefluence.pendingToken")
        preferences.set("customer", forKey: "codefluence.pendingAppUserId")
        preferences.set("manual-key", forKey: "codefluence.pendingIdempotencyKey")
        preferences.set(4, forKey: "codefluence.pendingAttempts")
        let done = expectation(description: "manual retry")
        sdk.retryPendingConfirmation { result in
            XCTAssertEqual(try? result.get(), "lead-fixture")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(RetryMockProtocol.requests.first?.idempotencyKey, "manual-key")
    }
}
