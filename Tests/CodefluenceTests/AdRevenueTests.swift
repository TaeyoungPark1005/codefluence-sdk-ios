import XCTest
import Foundation
@testable import Codefluence

private final class AdMockProtocol: URLProtocol {
    struct Recorded { let path: String; let method: String; let body: [String: Any]?; let authorization: String? }
    private static let lock = NSLock()
    private static var recorded: [Recorded] = []
    /// One queue of answers per path. The last answer repeats.
    static var responses: [String: [(Int, String)]] = [:]
    static var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset() { lock.lock(); recorded = []; responses = [:]; lock.unlock() }
    static func answer(_ path: String, _ answers: (Int, String)...) { lock.lock(); responses[path] = answers; lock.unlock() }
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
        var queue = Self.responses[path] ?? [(404, "{}")]
        let answer = queue.count > 1 ? queue.removeFirst() : queue[0]
        Self.responses[path] = queue
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class AdFakeAppAttest: CodefluenceAppAttest {
    var isSupported = true
    var generatedKeys = 0
    var assertions: [Data] = []
    func generateKey() async throws -> String { generatedKeys += 1; return "key-id-\(generatedKeys)-aaaaaaaaaaaaaaaaaaaa" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { assertions.append(clientDataHash); return Data("assertion-\(assertions.count)".utf8) }
}

final class AdRevenueTests: XCTestCase {
    private var suite: String!
    private var preferences: UserDefaults!
    private var session: URLSession!
    private var sdk: Codefluence!
    private var attest: AdFakeAppAttest!
    private var now = Date(timeIntervalSince1970: 1_790_040_000)

    override func setUp() {
        suite = "codefluence-adrev-tests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AdMockProtocol.self]
        session = URLSession(configuration: config)
        AdMockProtocol.reset()
        attest = AdFakeAppAttest()
        sdk = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session)
        sdk.appAttest = attest
        sdk.signalClock = { [unowned self] in self.now }
        AdMockProtocol.answer("/track/signal-config", (200, #"{"enabled":true,"platform":"ios","adRevenue":true}"#))
        AdMockProtocol.answer("/track/signal-challenge", (200, #"{"collect":true,"challenge":"challenge-abc","expiresAt":"2030-01-01T00:00:00Z"}"#))
        AdMockProtocol.answer("/track/signal-attest", (200, #"{"registered":true}"#))
        AdMockProtocol.answer("/track/ad-revenue", (200, #"{"accepted":true,"attested":true}"#))
    }
    override func tearDown() {
        session.invalidateAndCancel()
        preferences.removePersistentDomain(forName: suite)
        sdk = nil; session = nil; preferences = nil; attest = nil
    }
    private func paths() -> [String] { AdMockProtocol.requests.map { $0.path } }
    private func confirm() {
        preferences.set("lead-1", forKey: "codefluence.confirmedLeadId")
        preferences.set("token-1", forKey: "codefluence.confirmedPurchaseAccountToken")
    }
    /// Direct buffer write so the test controls when the flush runs (the public API also triggers a background flush).
    private func buffer(_ currency: String, micros: Int, impressions: Int, unknown: Int = 0) {
        preferences.set([currency: [micros, impressions, unknown]], forKey: Codefluence.AdRevenueKey.pending)
    }

    func testNothingLeavesTheDeviceWhenTheServerHasAdRevenueOff() async {
        AdMockProtocol.answer("/track/signal-config", (200, #"{"enabled":true,"platform":"ios"}"#))
        buffer("USD", micros: 1_500_000, impressions: 2)
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .skipped(reason: "disabled"))
        XCTAssertEqual(paths(), ["/track/signal-config"])
        // The only request carries the public key and no identifier; the batch stays on the device.
        XCTAssertEqual(AdMockProtocol.requests[0].authorization, "Bearer pk_fixture")
        XCTAssertNil(AdMockProtocol.requests[0].body)
        XCTAssertNotNil(preferences.dictionary(forKey: Codefluence.AdRevenueKey.pending))
    }

    func testNoBatchNoRequest() async {
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .skipped(reason: "nothing_pending"))
        XCTAssertTrue(paths().isEmpty)
    }

    func testInstallWithoutReferralSendsTheUnprovenTotalWithoutAnyIdentifier() async {
        buffer("USD", micros: 1_500_000, impressions: 2, unknown: 1)
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .sent(attested: false))
        XCTAssertEqual(paths(), ["/track/signal-config", "/track/ad-revenue"])
        let body = AdMockProtocol.requests[1].body!
        XCTAssertEqual(Set(body.keys), ["report", "build"])
        XCTAssertEqual(body["build"] as? String, expectedBuild, "소개되지 않은 설치의 합계에도 빌드 종류가 실려야 한다")
        let report = body["report"] as! [String: Any]
        XCTAssertEqual(report["currency"] as? String, "USD")
        XCTAssertEqual(report["valueMicros"] as? Int, 1_500_000)
        XCTAssertEqual(report["impressions"] as? Int, 2)
        XCTAssertEqual(report["unknownImpressions"] as? Int, 1)
        XCTAssertEqual(attest.generatedKeys, 0)
        XCTAssertNil(preferences.dictionary(forKey: Codefluence.AdRevenueKey.pending))
    }

    func testReferredInstallSendsAProvenBatchSignedOverTheExactValues() async {
        confirm()
        buffer("USD", micros: 1_500_000, impressions: 2, unknown: 1)
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .sent(attested: true))
        XCTAssertEqual(paths().filter { $0 == "/track/ad-revenue" }.count, 1)
        let sent = AdMockProtocol.requests.last!.body!
        XCTAssertEqual(sent["leadId"] as? String, "lead-1")
        XCTAssertEqual(sent["purchaseAccountToken"] as? String, "token-1")
        XCTAssertEqual(sent["challenge"] as? String, "challenge-abc")
        let proof = sent["proof"] as! [String: Any]
        XCTAssertEqual(proof["type"] as? String, "app_attest")
        // The assertion is signed over `challenge\ncurrency,micros,impressions,unknown`, the same string the server rebuilds.
        XCTAssertEqual(attest.assertions.last, Codefluence.sha256Data("challenge-abc\nUSD,1500000,2,1"))
        // The challenge for this purpose was requested with the ad revenue purpose.
        let purposes = AdMockProtocol.requests.filter { $0.path == "/track/signal-challenge" }.compactMap { $0.body?["purpose"] as? String }
        XCTAssertEqual(purposes, ["attest", "ad_revenue"])
    }

    func testRejectedProofFallsBackToTheUnprovenTotalSoTheRevenueIsNotLost() async {
        confirm()
        buffer("USD", micros: 2_000_000, impressions: 3)
        AdMockProtocol.answer("/track/ad-revenue", (200, #"{"accepted":true,"attested":false,"reason":"assertion_invalid"}"#), (200, #"{"accepted":true,"attested":false}"#))
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .sent(attested: false))
        let sends = AdMockProtocol.requests.filter { $0.path == "/track/ad-revenue" }
        XCTAssertEqual(sends.count, 2)
        XCTAssertNotNil(sends[0].body?["leadId"])
        XCTAssertNil(sends[1].body?["leadId"])
    }

    func testInstallWithoutAttestationSupportSendsTheUnprovenTotal() async {
        confirm(); attest.isSupported = false
        buffer("USD", micros: 500_000, impressions: 1)
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .sent(attested: false))
        XCTAssertNil(AdMockProtocol.requests.last!.body?["leadId"])
    }

    func testServerStoppingTheReferralWindowKeepsReportingTheUnprovenTotal() async {
        confirm()
        buffer("USD", micros: 500_000, impressions: 1)
        AdMockProtocol.answer("/track/signal-challenge", (200, #"{"collect":true,"challenge":"c1"}"#), (200, #"{"collect":false,"reason":"window_closed"}"#))
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .sent(attested: false))
        XCTAssertEqual(preferences.string(forKey: Codefluence.AdRevenueKey.stoppedLeadId), "lead-1")
        // Stopping the ad revenue report does not stop the daily activity signal.
        XCTAssertNil(preferences.string(forKey: Codefluence.SignalKey.stoppedLeadId))
    }

    func testAtMostOneBatchPerHour() async {
        buffer("USD", micros: 100_000, impressions: 1)
        let first = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(first, .sent(attested: false))
        buffer("USD", micros: 100_000, impressions: 1)
        let early = await sdk.performAdRevenueFlush(now: now.addingTimeInterval(600))
        XCTAssertEqual(early, .skipped(reason: "interval"))
        let later = await sdk.performAdRevenueFlush(now: now.addingTimeInterval(3601))
        XCTAssertEqual(later, .sent(attested: false))
    }

    func testRateLimitedBatchIsKeptAndRetriedLater() async {
        buffer("USD", micros: 700_000, impressions: 2)
        AdMockProtocol.answer("/track/ad-revenue", (429, #"{"error":"ad_revenue_rate_limited"}"#))
        let outcome = await sdk.performAdRevenueFlush(now: now)
        XCTAssertEqual(outcome, .skipped(reason: "rate_limited"))
        let kept = preferences.dictionary(forKey: Codefluence.AdRevenueKey.pending) as? [String: [Int]]
        XCTAssertEqual(kept?["USD"], [700_000, 2, 0])
        let during = await sdk.performAdRevenueFlush(now: now.addingTimeInterval(1800))
        XCTAssertEqual(during, .skipped(reason: "backoff"))
    }

    func testPublicReportConvertsDecimalsAndIgnoresUnsupportedInput() {
        AdMockProtocol.answer("/track/signal-config", (200, #"{"enabled":false,"platform":"ios"}"#))
        sdk.reportAdRevenue(value: Decimal(string: "0.005")!, currencyCode: "usd", precision: .precise)
        sdk.reportAdRevenue(value: Decimal(string: "0.001")!, currencyCode: "USD", precision: .estimated)
        sdk.reportAdRevenue(value: Decimal(string: "0.5")!, currencyCode: "USD", precision: .unknown)
        sdk.reportAdRevenue(value: Decimal(string: "1")!, currencyCode: "GBP", precision: .precise)
        sdk.reportAdRevenue(value: Decimal(-1), currencyCode: "USD", precision: .precise)
        sdk.reportAdRevenue(valueMicros: -5, currencyCode: "USD", precision: .precise)
        let pending = preferences.dictionary(forKey: Codefluence.AdRevenueKey.pending) as? [String: [Int]]
        // Unknown precision (test ads) counts the impression and adds no revenue.
        XCTAssertEqual(pending, ["USD": [6000, 2, 1]])
    }
}
