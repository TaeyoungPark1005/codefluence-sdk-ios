import XCTest
import Foundation
@testable import Codefluence

// 통합 헬퍼(start / handle(url:) / resume / purchaseCompleted). 개발자가 순서를 직접 맞추지 않아도
// 딥링크가 사용자 ID보다 먼저 와도, 시작 직후 "귀속 없음"이 확정되어도 소개가 사라지지 않아야 한다.
private final class HelperMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [(path: String, body: [String: Any])] = []
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
        let object = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        Self.lock.lock(); Self.captured.append((request.url?.path ?? "", object)); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"leadId\":\"lead-1\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private struct OneTransaction: StoreTransactionSource {
    func appTransactionJWS() async -> String? { nil }
    func signedTransactions() async -> [(transactionId: String, jws: String)] { [("tx-1", "jws-1")] }
}

private let signedToken = "6902082a-b202-4f7f-9b61-6ec419fb3b81.481e73f0-b627-482a-9466-5bc004807ff9.1796533770.UTM7ns4CUi-k-rI8rPXizYq5kjXadqEi5hP_jSA2JYM"

@MainActor
final class StartHelperTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var userId: String? = "user-1"

    override func setUp() {
        suite = "start-helper-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        HelperMockProtocol.reset()
        userId = "user-1"
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func makeSDK() -> Codefluence {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HelperMockProtocol.self]
        let sdk = Codefluence(publicKey: "pk_test", apiHost: URL(string: "https://api.example.test")!, preferences: defaults, session: URLSession(configuration: configuration))
        sdk.transactionSource = OneTransaction()
        return sdk
    }
    private func confirms() -> [[String: Any]] { HelperMockProtocol.requests.filter { $0.path.hasSuffix("/track/confirm") }.map { $0.body } }
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testReferralURLIsConfirmedWithTheHostUserId() {
        let sdk = makeSDK()
        sdk.begin(appUserId: { self.userId }, launchGrace: 3600, scheduler: { _, _ in })
        let handled = sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(signedToken)")!)
        XCTAssertTrue(handled)
        waitUntil { !self.confirms().isEmpty }
        XCTAssertEqual(confirms().first?["clickToken"] as? String, signedToken, "점이 들어간 전체 서명 토큰이 그대로 가야 한다")
        XCTAssertEqual(confirms().first?["appUserId"] as? String, "user-1")
    }

    func testNonReferralURLIsIgnored() {
        let sdk = makeSDK()
        sdk.begin(appUserId: { self.userId }, launchGrace: 3600, scheduler: { _, _ in })
        XCTAssertFalse(sdk.handle(url: URL(string: "adledger://settings")!))
        XCTAssertFalse(sdk.handle(url: URL(string: "https://example.com/other")!))
        XCTAssertTrue(confirms().isEmpty)
    }

    func testReferralBeforeUserIdIsKnownWaitsAndConfirmsOnResume() {
        userId = nil
        let sdk = makeSDK()
        sdk.begin(appUserId: { self.userId }, launchGrace: 3600, scheduler: { _, _ in })
        XCTAssertTrue(sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(signedToken)")!))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(confirms().isEmpty, "사용자 ID가 없으면 보내지 않는다")
        XCTAssertFalse(defaults.bool(forKey: "codefluence.decisionMade"), "ID가 없다는 이유로 귀속 없음을 확정하면 안 된다")
        userId = "late-user"
        sdk.resume()
        waitUntil { !self.confirms().isEmpty }
        XCTAssertEqual(confirms().first?["appUserId"] as? String, "late-user")
        XCTAssertEqual(confirms().first?["clickToken"] as? String, signedToken)
    }

    func testLaunchWithoutTokenDoesNotDecideBeforeTheDeepLinkCanArrive() {
        var scheduled: [() -> Void] = []
        let sdk = makeSDK()
        sdk.begin(appUserId: { self.userId }, launchGrace: 0.8, scheduler: { _, work in scheduled.append(work) })
        XCTAssertFalse(defaults.bool(forKey: "codefluence.decisionMade"), "시작 직후에는 결정하지 않는다")
        // 콜드 스타트에서 딥링크는 시작보다 늦게 도착한다.
        XCTAssertTrue(sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(signedToken)")!))
        waitUntil { !self.confirms().isEmpty }
        XCTAssertEqual(confirms().count, 1)
        scheduled.forEach { $0() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(confirms().count, 1, "유예 시간이 끝나도 같은 소개를 다시 보내지 않는다")
    }

    func testGraceElapsedWithoutAnyLinkRecordsNoAttributionOnce() {
        var scheduled: [() -> Void] = []
        let sdk = makeSDK()
        sdk.begin(appUserId: { self.userId }, launchGrace: 0.8, scheduler: { _, work in scheduled.append(work) })
        XCTAssertEqual(scheduled.count, 1)
        scheduled.forEach { $0() }
        waitUntil { self.defaults.bool(forKey: "codefluence.noTokenAtLaunch") }
        XCTAssertTrue(defaults.bool(forKey: "codefluence.noTokenAtLaunch"))
        XCTAssertTrue(confirms().isEmpty)
    }

    func testPurchaseCompletedReportsOnlyAfterAReferralWasConfirmed() {
        let sdk = makeSDK()
        sdk.begin(appUserId: { self.userId }, launchGrace: 3600, scheduler: { _, _ in })
        sdk.purchaseCompleted()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(HelperMockProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }.isEmpty, "소개로 온 적 없는 설치의 결제는 보내지 않는다")

        XCTAssertTrue(sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(signedToken)")!))
        waitUntil { !self.confirms().isEmpty }
        waitUntil { !HelperMockProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }.isEmpty }
        sdk.purchaseCompleted()
        waitUntil { !HelperMockProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }.isEmpty }
        XCTAssertFalse(HelperMockProtocol.requests.filter { $0.path.hasSuffix("/track/purchase") }.isEmpty)
    }
}
