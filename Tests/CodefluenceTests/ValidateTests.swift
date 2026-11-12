import XCTest
import Foundation
@testable import Codefluence

// 설치 점검(validate)과 heartbeat 계약. 다른 SDK(Branch의 integration validator, AppsFlyer의 연동 테스트)처럼
// 개발자가 출시 전에 "키·서버·스킴이 맞는지"를 한 번에 확인하고, 서버에는 첫 신호가 바로 도착해야 한다.
private final class ValidateMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [(path: String, body: [String: Any])] = []
    static var status = 200
    static var failWithNetworkError = false
    static var requests: [(path: String, body: [String: Any])] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured = []; status = 200; failWithNetworkError = false; lock.unlock() }
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
        Self.lock.lock(); Self.captured.append((request.url?.path ?? "", object)); let status = Self.status; let fail = Self.failWithNetworkError; Self.lock.unlock()
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class ValidateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    override func setUp() {
        suite = "validate-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        ValidateMockProtocol.reset()
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func makeSDK(key: String = "pk_test") -> Codefluence {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ValidateMockProtocol.self]
        return Codefluence(publicKey: key, apiHost: URL(string: "https://api.example.test")!, preferences: defaults, session: URLSession(configuration: configuration))
    }
    private func run(_ sdk: Codefluence, scheme: String? = nil, schemes: [String] = []) -> [CodefluenceCheck] {
        sdk.registeredURLSchemes = { schemes }
        let done = expectation(description: "validate")
        var result: [CodefluenceCheck] = []
        sdk.validate(urlScheme: scheme) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }
    private func check(_ checks: [CodefluenceCheck], _ name: String) -> CodefluenceCheck? { checks.first { $0.name == name } }

    func testHealthySetupPassesEveryCheck() {
        let checks = run(makeSDK(), scheme: "adledger", schemes: ["adledger"])
        XCTAssertEqual(checks.map(\.name), ["설정", "서버와 키", "빌드", "URL 스킴"])
        XCTAssertTrue(checks.allSatisfy(\.passed), "\(checks)")
        XCTAssertEqual(ValidateMockProtocol.requests.filter { $0.path == "/sdk/heartbeat" }.count, 1, "점검이 첫 신호로도 도착해야 한다")
    }

    func testValidateHeartbeatCarriesTheBuildKind() {
        _ = run(makeSDK())
        let body = ValidateMockProtocol.requests.first { $0.path == "/sdk/heartbeat" }?.body
        XCTAssertEqual(body?["build"] as? String, expectedBuild, "점검 신호가 개발 빌드인지 서버가 알아야 운영 집계에서 뺀다")
        XCTAssertEqual(body?["sdkVersion"] as? String, "0.2.2")
    }

    func testBuildCheckTellsWhetherSignalsCountInProduction() {
        let checks = run(makeSDK())
        let build = check(checks, "빌드")
        XCTAssertEqual(build?.passed, true, "빌드 종류는 안내 항목이라 점검 실패로 치지 않는다")
        XCTAssertEqual(build?.hint, Codefluence.buildCheck(expectedBuild).hint)
        let debug = Codefluence.buildCheck("debug").hint
        XCTAssertTrue(debug.contains("개발 빌드") && debug.contains("운영 집계") && debug.contains("들어가지 않아요"), debug)
        XCTAssertTrue(Codefluence.buildCheck("release").hint.contains("출시 빌드"))
    }

    func testRejectedKeyExplainsWhatToCheck() {
        ValidateMockProtocol.status = 401
        let server = check(run(makeSDK()), "서버와 키")
        XCTAssertEqual(server?.passed, false)
        XCTAssertTrue(server?.hint.contains("pk_") == true && server?.hint.contains("폐기") == true, server?.hint ?? "")
    }

    func testPlatformMismatchExplainsWhichProductKeyToUse() {
        ValidateMockProtocol.status = 422
        let server = check(run(makeSDK()), "서버와 키")
        XCTAssertEqual(server?.passed, false)
        XCTAssertTrue(server?.hint.contains("플랫폼") == true, server?.hint ?? "")
    }

    func testUnreachableServerPointsAtTheNetworkAndHost() {
        ValidateMockProtocol.failWithNetworkError = true
        let server = check(run(makeSDK()), "서버와 키")
        XCTAssertEqual(server?.passed, false)
        XCTAssertTrue(server?.hint.contains("주소") == true, server?.hint ?? "")
    }

    func testMissingUrlSchemeIsReportedWithTheFix() {
        let scheme = check(run(makeSDK(), scheme: "adledger", schemes: ["other"]), "URL 스킴")
        XCTAssertEqual(scheme?.passed, false)
        XCTAssertTrue(scheme?.hint.contains("URL Types") == true && scheme?.hint.contains("adledger") == true, scheme?.hint ?? "")
    }

    func testWrongKeyShapeFailsLocallyWithoutANetworkCall() {
        let checks = run(makeSDK(key: "sk_live_wrong"))
        XCTAssertEqual(check(checks, "설정")?.passed, false)
        XCTAssertTrue(ValidateMockProtocol.requests.isEmpty, "비밀 키 모양이면 서버로 보내지 않는다")
    }

    #if canImport(UIKit)
    func testHeartbeatBodyMatchesTheServerContract() {
        let sdk = makeSDK()
        let done = expectation(description: "heartbeat")
        sdk.heartbeat { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        let body = ValidateMockProtocol.requests.first { $0.path == "/sdk/heartbeat" }?.body
        XCTAssertEqual(body?["platform"] as? String, "ios", "서버 스키마는 platform을 요구한다")
        XCTAssertNotNil(body?["appVersion"] as? String)
        XCTAssertNotNil(body?["sdkVersion"] as? String)
        XCTAssertNil(body?["attestation"], "증명이 없으면 키를 빼야 한다(null은 서버가 400으로 거절한다)")
    }

    @MainActor
    func testStartSendsTheFirstSignalOncePerDay() {
        let sdk = makeSDK()
        sdk.begin(appUserId: { nil }, launchGrace: 3600, scheduler: { _, _ in })
        let deadline = Date().addingTimeInterval(5)
        while ValidateMockProtocol.requests.filter({ $0.path == "/sdk/heartbeat" }).isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(ValidateMockProtocol.requests.filter { $0.path == "/sdk/heartbeat" }.count, 1, "시작만 해도 대시보드에 SDK 신호가 떠야 한다")
        sdk.begin(appUserId: { nil }, launchGrace: 3600, scheduler: { _, _ in })
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(ValidateMockProtocol.requests.filter { $0.path == "/sdk/heartbeat" }.count, 1, "같은 날 두 번째 시작은 다시 보내지 않는다")
    }
    #endif
}

// 서버가 같은 고객의 다른 설치(재설치 등)를 409로 거절하면 일반 네트워크 오류가 아니라 전용 오류로 알려 개발자가 구별할 수 있어야 한다.
final class ConfirmationRejectedTests: XCTestCase {
    func testErrorCodeAndRetryability() {
        let error = CodefluenceError.confirmationRejected
        XCTAssertEqual(error.code, 14)
        XCTAssertFalse(error.isRetryable)
        XCTAssertEqual((error as NSError).code, 14)
        XCTAssertTrue(error.message.contains("rejected"))
    }
}
