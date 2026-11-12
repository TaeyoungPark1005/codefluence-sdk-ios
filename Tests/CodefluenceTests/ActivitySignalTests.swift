import XCTest
import Foundation
@testable import Codefluence

private final class SignalMockProtocol: URLProtocol {
    struct Recorded { let path: String; let method: String; let body: [String: Any]?; let authorization: String? }
    private static let lock = NSLock()
    private static var recorded: [Recorded] = []
    static var responses: [String: (Int, String)] = [:]
    static var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset() { lock.lock(); recorded = []; responses = [:]; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); var collected = Data(); let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
            while stream.hasBytesAvailable { let n = stream.read(buffer, maxLength: 4096); if n <= 0 { break }; collected.append(buffer, count: n) }
            stream.close(); data = collected
        }
        let path = request.url!.path
        Self.lock.lock()
        Self.recorded.append(Recorded(path: path, method: request.httpMethod ?? "GET", body: data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }, authorization: request.value(forHTTPHeaderField: "Authorization")))
        let answer = Self.responses[path] ?? (404, "{}")
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class FakeAppAttest: CodefluenceAppAttest {
    var isSupported = true
    var generatedKeys = 0
    var attestations: [Data] = []
    var assertions: [Data] = []
    func generateKey() async throws -> String { generatedKeys += 1; return "key-id-\(generatedKeys)-aaaaaaaaaaaaaaaaaaaa" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { attestations.append(clientDataHash); return Data("attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { assertions.append(clientDataHash); return Data("assertion-\(assertions.count)".utf8) }
}

final class ActivitySignalTests: XCTestCase {
    private var suite: String!
    private var preferences: UserDefaults!
    private var session: URLSession!
    private var sdk: Codefluence!
    private var attest: FakeAppAttest!
    private var now = Date(timeIntervalSince1970: 1_790_040_000)

    override func setUp() {
        suite = "codefluence-activity-tests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SignalMockProtocol.self]
        session = URLSession(configuration: config)
        SignalMockProtocol.reset()
        attest = FakeAppAttest()
        sdk = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session)
        sdk.appAttest = attest
        sdk.signalClock = { [unowned self] in self.now }
        preferences.set("lead-1", forKey: "codefluence.confirmedLeadId")
        preferences.set("token-1", forKey: "codefluence.confirmedPurchaseAccountToken")
        SignalMockProtocol.responses["/track/signal-config"] = (200, #"{"enabled":true,"platform":"ios"}"#)
        SignalMockProtocol.responses["/track/signal-challenge"] = (200, #"{"collect":true,"challenge":"challenge-abc","expiresAt":"2030-01-01T00:00:00Z"}"#)
        SignalMockProtocol.responses["/track/signal-attest"] = (200, #"{"registered":true}"#)
        SignalMockProtocol.responses["/track/signal"] = (200, #"{"accepted":true,"attested":true,"day":"2026-11-11"}"#)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        preferences.removePersistentDomain(forName: suite)
        sdk = nil; session = nil; preferences = nil; attest = nil
    }

    private func paths() -> [String] { SignalMockProtocol.requests.map { $0.path } }

    func testSendsNothingWhenServerFlagIsOff() async {
        SignalMockProtocol.responses["/track/signal-config"] = (200, #"{"enabled":false,"platform":"ios","reason":"disabled"}"#)
        let outcome = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome, .skipped(reason: "disabled"))
        XCTAssertEqual(paths(), ["/track/signal-config"])
        // The only request carries the public key and no install, lead or device identifier.
        let config = SignalMockProtocol.requests[0]
        XCTAssertEqual(config.method, "GET"); XCTAssertNil(config.body); XCTAssertEqual(config.authorization, "Bearer pk_fixture")
        XCTAssertEqual(attest.generatedKeys, 0)
        // A disabled answer is cached, so the next launch within the TTL does not even ask again.
        _ = await sdk.performActivitySignal(now: now.addingTimeInterval(60))
        XCTAssertEqual(paths(), ["/track/signal-config"])
    }

    func testNothingLeavesTheDeviceWithoutAConfirmedReferralOrAttestationSupport() async {
        preferences.removeObject(forKey: "codefluence.confirmedLeadId")
        let outcome1 = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome1, .skipped(reason: "not_confirmed"))
        preferences.set("lead-1", forKey: "codefluence.confirmedLeadId")
        attest.isSupported = false
        let outcome2 = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome2, .skipped(reason: "attestation_unsupported"))
        XCTAssertTrue(paths().isEmpty)
    }

    func testRegistersTheKeyOnceThenSendsSignedDailySignalWithClientDataBoundToChallenge() async throws {
        let outcome = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome, .sent(attested: true))
        XCTAssertEqual(paths(), ["/track/signal-config", "/track/signal-challenge", "/track/signal-attest", "/track/signal-challenge", "/track/signal"])
        let attestBody = try XCTUnwrap(SignalMockProtocol.requests[2].body)
        XCTAssertEqual(attestBody["leadId"] as? String, "lead-1")
        XCTAssertEqual(attestBody["purchaseAccountToken"] as? String, "token-1")
        XCTAssertEqual(attestBody["build"] as? String, expectedBuild)
        XCTAssertEqual(attestBody["challenge"] as? String, "challenge-abc")
        XCTAssertEqual(attestBody["keyId"] as? String, "key-id-1-aaaaaaaaaaaaaaaaaaaa")
        // attestKey signs SHA-256(challenge); the assertion signs SHA-256(challenge + "\n" + milestones).
        XCTAssertEqual(attest.attestations.first, Codefluence.sha256Data("challenge-abc"))
        XCTAssertEqual(attest.assertions.first, Codefluence.sha256Data("challenge-abc\n"))
        let signal = try XCTUnwrap(SignalMockProtocol.requests[4].body)
        let proof = try XCTUnwrap(signal["proof"] as? [String: Any])
        XCTAssertEqual(proof["type"] as? String, "app_attest")
        XCTAssertEqual(proof["assertion"] as? String, Data("assertion-1".utf8).base64EncodedString())
        XCTAssertEqual(signal["milestones"] as? [String], [])
        XCTAssertEqual(signal["build"] as? String, expectedBuild)
        XCTAssertEqual(SignalMockProtocol.requests[1].body?["build"] as? String, expectedBuild, "challenge에도 빌드 종류가 실려야 서버가 운영 lead의 개발 빌드 수집을 멈출 수 있다")
        // Same KST day: no second request. Next day: signal only, the key is not registered again.
        let outcome3 = await sdk.performActivitySignal(now: now.addingTimeInterval(3600))
        XCTAssertEqual(outcome3, .skipped(reason: "already_sent_today"))
        SignalMockProtocol.reset()
        SignalMockProtocol.responses["/track/signal-challenge"] = (200, #"{"collect":true,"challenge":"challenge-2"}"#)
        SignalMockProtocol.responses["/track/signal"] = (200, #"{"accepted":true,"attested":true,"day":"2026-11-12"}"#)
        SignalMockProtocol.responses["/track/signal-config"] = (200, #"{"enabled":true,"platform":"ios"}"#)
        let outcome4 = await sdk.performActivitySignal(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(outcome4, .sent(attested: true))
        // 24 hours later the cached capability answer (6 hour TTL) is stale, so it is asked again; the key is not registered again.
        XCTAssertEqual(paths(), ["/track/signal-config", "/track/signal-challenge", "/track/signal"])
        XCTAssertEqual(attest.generatedKeys, 1)
    }

    func testMilestonesAreValidatedSentOnceAndBoundIntoTheSignature() async throws {
        sdk.trackMilestone("bad name!")
        sdk.trackMilestone(String(repeating: "a", count: 41))
        XCTAssertNil(preferences.stringArray(forKey: Codefluence.SignalKey.pendingMilestones))
        preferences.set(["onboarded"], forKey: Codefluence.SignalKey.pendingMilestones)
        _ = await sdk.performActivitySignal(now: now)
        let signal = try XCTUnwrap(SignalMockProtocol.requests.last?.body)
        XCTAssertEqual(signal["milestones"] as? [String], ["onboarded"])
        XCTAssertEqual(attest.assertions.last, Codefluence.sha256Data("challenge-abc\nonboarded"))
        XCTAssertEqual(preferences.stringArray(forKey: Codefluence.SignalKey.sentMilestones), ["onboarded"])
        XCTAssertEqual(preferences.stringArray(forKey: Codefluence.SignalKey.pendingMilestones), [])
        // A new milestone on the same day allows exactly one more signal.
        preferences.set(["second"], forKey: Codefluence.SignalKey.pendingMilestones)
        let outcome5 = await sdk.performActivitySignal(now: now.addingTimeInterval(600))
        XCTAssertEqual(outcome5, .sent(attested: true))
        let outcome6 = await sdk.performActivitySignal(now: now.addingTimeInterval(900))
        XCTAssertEqual(outcome6, .skipped(reason: "already_sent_today"))
    }

    func testAnUnattestedAnswerKeepsMilestonesPendingAndDoesNotCountTheDay() async {
        SignalMockProtocol.responses["/track/signal"] = (200, #"{"accepted":true,"attested":false,"day":"2026-11-11","reason":"bad_signature"}"#)
        preferences.set(["onboarded"], forKey: Codefluence.SignalKey.pendingMilestones)
        let outcome7 = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome7, .sent(attested: false))
        XCTAssertNil(preferences.string(forKey: Codefluence.SignalKey.lastDay))
        XCTAssertEqual(preferences.stringArray(forKey: Codefluence.SignalKey.pendingMilestones), ["onboarded"])
    }

    func testStopsForeverWhenTheServerDoesNotCollectForThisInstall() async {
        SignalMockProtocol.responses["/track/signal-challenge"] = (200, #"{"collect":false,"reason":"window_closed"}"#)
        let outcome8 = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome8, .skipped(reason: "not_collecting"))
        SignalMockProtocol.reset()
        let outcome9 = await sdk.performActivitySignal(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(outcome9, .skipped(reason: "stopped"))
        XCTAssertTrue(paths().isEmpty)
    }

    func testAttemptsPerDayAreCappedSoFailuresCannotLoop() async {
        SignalMockProtocol.responses["/track/signal"] = (500, "{}")
        for _ in 0..<Codefluence.maxSignalAttemptsPerDay { _ = await sdk.performActivitySignal(now: now) }
        SignalMockProtocol.reset()
        let outcome10 = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome10, .skipped(reason: "attempt_limit"))
        XCTAssertTrue(paths().isEmpty)
    }

    func testRateLimitAndKeyConflictResponsesNeverThrow() async {
        SignalMockProtocol.responses["/track/signal"] = (429, #"{"error":"signal_rate_limited"}"#)
        let outcome11 = await sdk.performActivitySignal(now: now)
        XCTAssertEqual(outcome11, .skipped(reason: "rate_limited"))
        preferences.removeObject(forKey: Codefluence.SignalKey.attemptsDay)
        preferences.removeObject(forKey: Codefluence.SignalKey.attestRegisteredLeadId)
        SignalMockProtocol.responses["/track/signal-attest"] = (409, #"{"error":"key_already_registered"}"#)
        let outcome12 = await sdk.performActivitySignal(now: now.addingTimeInterval(1))
        XCTAssertEqual(outcome12, .skipped(reason: "key_conflict"))
    }

    func testMilestoneNameRules() {
        XCTAssertTrue(Codefluence.validMilestone("first_post-1.0"))
        XCTAssertFalse(Codefluence.validMilestone(""))
        XCTAssertFalse(Codefluence.validMilestone("한글"))
        XCTAssertFalse(Codefluence.validMilestone("a b"))
        XCTAssertEqual(Codefluence.kstDay(Date(timeIntervalSince1970: 1_790_040_000)), "2026-09-22")
    }

    func testSdkVersionIs021() { XCTAssertEqual(Codefluence.version, "0.2.1") }
}
