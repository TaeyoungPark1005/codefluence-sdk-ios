import XCTest
import Foundation
@testable import Codefluence

// 결제 SDK(RevenueCat 등)로 결제한 앱도 귀속되도록, SDK가 스토어에서 거래를 직접 읽어 보고한다.
// 계획: docs/superpowers/plans/2026-11-05-store-read-attribution-and-device-test.md Task 4
private final class MockPurchaseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [(path: String, body: [String: Any])] = []
    static var reply: (String) -> (Int, String) = { _ in (200, "{\"leadId\":\"lead-fixture\"}") }
    static var requests: [(path: String, body: [String: Any])] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
        }
        let path = request.url?.path ?? ""
        let object = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        Self.lock.lock(); Self.captured.append((path, object)); let (status, text) = Self.reply(path); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private struct SlowSource: StoreTransactionSource {
    func appTransactionJWS() async -> String? { try? await Task.sleep(nanoseconds: 3_000_000_000); return "too-late" }
    func signedTransactions() async -> [(transactionId: String, jws: String)] { [] }
}

private final class Counter: @unchecked Sendable { private let lock = NSLock(); private var n = 0; func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n } }

private final class CountingSource: StoreTransactionSource {
    private var calls = 0
    func appTransactionJWS() async -> String? { calls += 1; return "jws-\(calls)" }
    func signedTransactions() async -> [(transactionId: String, jws: String)] { [] }
}

private struct SlowTransactions: StoreTransactionSource {
    func appTransactionJWS() async -> String? { nil }
    func signedTransactions() async -> [(transactionId: String, jws: String)] { try? await Task.sleep(nanoseconds: 300_000_000); return [("tx-1", "jws-1")] }
}

private struct FakeSource: StoreTransactionSource {
    var appJWS: String?
    var transactions: [(transactionId: String, jws: String)]
    func appTransactionJWS() async -> String? { appJWS }
    func signedTransactions() async -> [(transactionId: String, jws: String)] { transactions }
}

final class PurchaseReportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    override func setUp() {
        suite = "purchase-report-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        MockPurchaseProtocol.reset()
        MockPurchaseProtocol.reply = { _ in (200, "{\"leadId\":\"lead-fixture\"}") }
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func sdk(configured: Bool = true, source: StoreTransactionSource) -> Codefluence {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPurchaseProtocol.self]
        let session = URLSession(configuration: configuration)
        let instance = configured
            ? Codefluence(publicKey: "pk_test", apiHost: URL(string: "https://api.example.test")!, preferences: defaults, session: session)
            : Codefluence(preferences: defaults, session: session)
        instance.transactionSource = source
        return instance
    }
    private func report(_ instance: Codefluence) -> Result<Int, Error> {
        let done = expectation(description: "report")
        var outcome: Result<Int, Error>!
        instance.reportPurchases { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return outcome
    }

    func testConfirmSendsAppTransactionJWS() {
        let instance = sdk(source: FakeSource(appJWS: "signed-app-transaction", transactions: []))
        let done = expectation(description: "confirm")
        instance.confirm(clickToken: "click-token", appUserId: "customer-1") { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        let confirm = MockPurchaseProtocol.requests.first { $0.path.hasSuffix("/track/confirm") }
        XCTAssertEqual(confirm?.body["appTransactionJws"] as? String, "signed-app-transaction")
    }

    func testSlowAppTransactionDoesNotBlockConfirm() {
        let instance = sdk(source: SlowSource())
        instance.appTransactionTimeout = 0.2
        let done = expectation(description: "confirm")
        instance.confirm(clickToken: "click-token", appUserId: "customer-1") { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        let confirm = MockPurchaseProtocol.requests.first { $0.path.hasSuffix("/track/confirm") }
        XCTAssertNotNil(confirm)
        XCTAssertNil(confirm?.body["appTransactionJws"])
    }

    /// A retry reuses the idempotency key, so its body must not change (server answers 409 otherwise).
    func testRetryResendsTheSameAppTransactionJWS() {
        let confirmCalls = Counter()
        MockPurchaseProtocol.reply = { path in path.hasSuffix("/track/confirm") && confirmCalls.next() == 1 ? (503, "{}") : (200, "{\"leadId\":\"lead-fixture\"}") }
        let instance = sdk(source: CountingSource())
        let first = expectation(description: "first")
        instance.confirm(clickToken: "click-token", appUserId: "customer-1") { _ in first.fulfill() }
        wait(for: [first], timeout: 5)
        let second = expectation(description: "retry")
        instance.retryPendingConfirmation { _ in second.fulfill() }
        wait(for: [second], timeout: 5)
        let bodies = MockPurchaseProtocol.requests.filter { $0.path.hasSuffix("/track/confirm") }.map { $0.body["appTransactionJws"] as? String }
        XCTAssertEqual(bodies, ["jws-1", "jws-1"])
    }

    func testOverlappingReportsSendOnce() {
        let instance = sdk(source: SlowTransactions())
        let both = expectation(description: "both"); both.expectedFulfillmentCount = 2
        instance.reportPurchases { _ in both.fulfill() }
        instance.reportPurchases { _ in both.fulfill() }
        wait(for: [both], timeout: 5)
        XCTAssertEqual(MockPurchaseProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }.count, 1)
    }

    func testReportPurchasesSendsOnlyUnreported() {
        defaults.set(["tx-1"], forKey: "codefluence.reportedTransactionIds")
        let instance = sdk(source: FakeSource(appJWS: nil, transactions: [("tx-1", "jws-1"), ("tx-2", "jws-2")]))
        XCTAssertEqual(try report(instance).get(), 1)
        let purchases = MockPurchaseProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }
        XCTAssertEqual(purchases.count, 1)
        XCTAssertEqual(purchases.first?.body["signedTransaction"] as? String, "jws-2")
        XCTAssertEqual(purchases.first?.body["build"] as? String, expectedBuild)
    }

    func testDuplicateResponseMarksReported() {
        MockPurchaseProtocol.reply = { _ in (200, "{\"deduplicated\":true}") }
        let instance = sdk(source: FakeSource(appJWS: nil, transactions: [("tx-1", "jws-1")]))
        XCTAssertEqual(try report(instance).get(), 1)
        XCTAssertEqual(try report(instance).get(), 0)
        XCTAssertEqual(MockPurchaseProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }.count, 1)
    }

    func testRejectedReportIsRetriedLater() {
        MockPurchaseProtocol.reply = { _ in (422, "{\"error\":\"purchase_verification_failed\"}") }
        let instance = sdk(source: FakeSource(appJWS: nil, transactions: [("tx-1", "jws-1")]))
        XCTAssertEqual(try report(instance).get(), 0)
        XCTAssertEqual(try report(instance).get(), 0)
        XCTAssertEqual(MockPurchaseProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }.count, 2)
    }

    func testNotConfiguredReturnsCode11() {
        let instance = sdk(configured: false, source: FakeSource(appJWS: nil, transactions: [("tx-1", "jws-1")]))
        guard case .failure(let error) = report(instance) else { return XCTFail("expected failure") }
        XCTAssertEqual((error as NSError).code, 11)
        XCTAssertTrue(MockPurchaseProtocol.requests.isEmpty)
    }
}
