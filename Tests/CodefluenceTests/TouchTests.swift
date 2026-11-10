import XCTest
import Foundation
@testable import Codefluence

// 이미 소개로 확인된 설치가 다른 크리에이터의 링크를 다시 열면 서버에 알린다(소모성 재결제 귀속의 근거). 첫 소개자는 바뀌지 않는다.
private final class TouchMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [(path: String, body: [String: Any])] = []
    static var status = 200
    static var requests: [(path: String, body: [String: Any])] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured = []; status = 200; lock.unlock() }
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
        Self.lock.lock(); Self.captured.append((request.url?.path ?? "", object)); let status = Self.status; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"recorded\":true,\"leadId\":\"lead-1\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private let tokenA = "6902082a-b202-4f7f-9b61-6ec419fb3b81.481e73f0-b627-482a-9466-5bc004807ff9.1796533770.UTM7ns4CUi-k-rI8rPXizYq5kjXadqEi5hP_jSA2JYM"
private let tokenB = "7a02082a-b202-4f7f-9b61-6ec419fb3b82.481e73f0-b627-482a-9466-5bc004807ff9.1796533999.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@MainActor
final class TouchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    override func setUp() {
        suite = "touch-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        TouchMockProtocol.reset()
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func confirmedSDK() -> Codefluence {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TouchMockProtocol.self]
        let sdk = Codefluence(publicKey: "pk_test", apiHost: URL(string: "https://api.example.test")!, preferences: defaults, session: URLSession(configuration: configuration))
        // 첫 소개(A)로 이미 확인된 설치.
        defaults.set(true, forKey: "codefluence.decisionMade"); defaults.set(true, forKey: "codefluence.accepted")
        defaults.set("lead-1", forKey: "codefluence.confirmedLeadId"); defaults.set("user-1", forKey: "codefluence.confirmedAppUserId")
        defaults.set(tokenA, forKey: "codefluence.clickToken")
        defaults.set("11111111-1111-4111-8111-111111111111", forKey: "codefluence.purchaseAccountToken")
        sdk.begin(appUserId: { "user-1" }, launchGrace: 3600, scheduler: { _, _ in })
        TouchMockProtocol.reset() // begin이 보낸 첫 신호는 비운다.
        return sdk
    }
    private func touches() -> [[String: Any]] { TouchMockProtocol.requests.filter { $0.path.hasSuffix("/track/touch") }.map { $0.body } }
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testAnotherCreatorsLinkIsReportedWithTheInstallToken() {
        let sdk = confirmedSDK()
        XCTAssertTrue(sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(tokenB)")!))
        waitUntil { !self.touches().isEmpty }
        XCTAssertEqual(touches().count, 1)
        XCTAssertEqual(touches().first?["clickToken"] as? String, tokenB)
        XCTAssertEqual(touches().first?["appUserId"] as? String, "user-1")
        XCTAssertEqual(touches().first?["purchaseAccountToken"] as? String, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(defaults.string(forKey: "codefluence.clickToken"), tokenA, "첫 소개 토큰은 바뀌지 않는다")
    }

    func testTheSameLinkIsReportedOnlyOnce() {
        let sdk = confirmedSDK()
        _ = sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(tokenB)")!)
        waitUntil { !self.touches().isEmpty }
        _ = sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(tokenB)")!)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(touches().count, 1)
    }

    func testTheOriginalLinkIsNotReportedAgain() {
        let sdk = confirmedSDK()
        _ = sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(tokenA)")!)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(touches().isEmpty)
    }

    func testAFailedReportIsRetriedWhenTheLinkIsOpenedAgain() {
        let sdk = confirmedSDK()
        TouchMockProtocol.status = 503
        _ = sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(tokenB)")!)
        waitUntil { !self.touches().isEmpty }
        TouchMockProtocol.status = 200
        _ = sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(tokenB)")!)
        waitUntil { self.touches().count >= 2 }
        XCTAssertEqual(touches().count, 2)
    }

    func testAnInstallThatWasNeverConfirmedSendsNoTouch() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TouchMockProtocol.self]
        let sdk = Codefluence(publicKey: "pk_test", apiHost: URL(string: "https://api.example.test")!, preferences: defaults, session: URLSession(configuration: configuration))
        sdk.begin(appUserId: { "user-1" }, launchGrace: 3600, scheduler: { _, _ in })
        _ = sdk.handle(url: URL(string: "adledger://referral?cf_click_token=\(tokenB)")!)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(touches().isEmpty, "확인된 적 없는 설치의 첫 링크는 평소 확인 경로로 처리된다")
    }
}
