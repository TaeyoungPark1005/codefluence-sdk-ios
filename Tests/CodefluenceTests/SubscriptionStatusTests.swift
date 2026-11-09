import XCTest
import Foundation
@testable import Codefluence

private final class SubscriptionMockProtocol: URLProtocol {
    static var status = 200
    static var body = "{}"
    private static let lock = NSLock()
    private static var urls: [URL?] = []
    static var requestedURLs: [URL?] { lock.lock(); defer { lock.unlock() }; return urls }
    static func reset() { lock.lock(); urls = []; lock.unlock(); status = 200; body = "{}" }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.urls.append(request.url); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class SubscriptionStatusTests: XCTestCase {
    private var suite: String!
    private var preferences: UserDefaults!
    private var session: URLSession!
    private var sdk: Codefluence!

    override func setUp() {
        suite = "codefluence-subscription-tests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SubscriptionMockProtocol.self]
        session = URLSession(configuration: config)
        SubscriptionMockProtocol.reset()
        sdk = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        preferences.removePersistentDomain(forName: suite)
        sdk = nil; session = nil; preferences = nil
    }

    private func storeConfirmedReferral() {
        preferences.set("lead-fixture", forKey: "codefluence.confirmedLeadId")
        preferences.set("pat-fixture", forKey: "codefluence.confirmedPurchaseAccountToken")
    }

    func testParsesStateSandboxUpdatedAtAndEvents() {
        storeConfirmedReferral()
        SubscriptionMockProtocol.body = """
        {"state":"active","sandbox":true,"updatedAt":"2026-10-28T00:00:00Z",
         "events":[{"type":"started","occurredAt":"2026-10-01T00:00:00Z","source":"app_store"},
                   {"type":"renewed","occurredAt":"2026-10-15T00:00:00Z","source":"app_store"}]}
        """
        let done = expectation(description: "parsed status")
        sdk.subscriptionStatus { result in
            guard let status = try? result.get() else { XCTFail("expected success"); done.fulfill(); return }
            XCTAssertEqual(status.state, .active)
            XCTAssertTrue(status.sandbox)
            XCTAssertEqual(status.updatedAt, "2026-10-28T00:00:00Z")
            XCTAssertEqual(status.events.count, 2)
            XCTAssertEqual(status.events.first?.kind, .started)
            XCTAssertEqual(status.events.last?.kind, .renewed)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(SubscriptionMockProtocol.requestedURLs.first??.absoluteString, "https://sdk-test.invalid/track/subscription")
    }

    func testUnknownEventTypePreservesRawTypeWithNilKind() {
        let parsed = Codefluence.parseSubscription([
            "state": "grace", "sandbox": false, "updatedAt": NSNull(),
            "events": [["type": "paused", "occurredAt": "2026-10-20T00:00:00Z", "source": "store"]]
        ])
        XCTAssertEqual(parsed?.state, .grace)
        XCTAssertNil(parsed?.updatedAt)
        XCTAssertNil(parsed?.events.first?.kind)
        XCTAssertEqual(parsed?.events.first?.rawType, "paused")
    }

    func testMissingConfirmedReferralFailsWithNoSubscriptionReference() {
        let done = expectation(description: "no reference")
        sdk.subscriptionStatus { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error as? CodefluenceError, .noSubscriptionReference)
                XCTAssertEqual((error as NSError).code, 12)
            } else { XCTFail("expected failure") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(SubscriptionMockProtocol.requestedURLs.isEmpty)
    }

    func testServer404MapsToSubscriptionNotFound() {
        storeConfirmedReferral()
        SubscriptionMockProtocol.status = 404
        SubscriptionMockProtocol.body = "{\"error\":\"subscription_not_found\"}"
        let done = expectation(description: "404")
        sdk.subscriptionStatus { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error as? CodefluenceError, .subscriptionNotFound)
                XCTAssertEqual((error as NSError).code, 13)
            } else { XCTFail("expected failure") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testFallsBackToLocalPurchaseAccountTokenWhenResponseTokenAbsent() {
        preferences.set("lead-fixture", forKey: "codefluence.confirmedLeadId")
        preferences.set("local-pat", forKey: "codefluence.purchaseAccountToken")
        SubscriptionMockProtocol.body = "{\"state\":\"none\",\"sandbox\":false,\"updatedAt\":null,\"events\":[]}"
        let done = expectation(description: "fallback pat")
        sdk.subscriptionStatus { result in
            XCTAssertEqual((try? result.get())?.state, CodefluenceSubscriptionStatus.State.none)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(SubscriptionMockProtocol.requestedURLs.count, 1)
    }
}
