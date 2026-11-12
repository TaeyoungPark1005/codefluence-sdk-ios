import XCTest
import Foundation
@testable import Codefluence

private final class MockConfirmationProtocol: URLProtocol {
    struct CapturedRequest { let url: URL?; let body: Data; let timeout: TimeInterval; let authorization: String? }
    private static let lock = NSLock()
    private static var captured: [CapturedRequest] = []
    static var reply: (Int) -> (Int, String, TimeInterval) = { _ in (200, "{\"leadId\":\"lead-fixture\"}", 0) }
    static var requests: [CapturedRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    // Intercept every host, so accidental fallback requests never leave unit tests.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.lock.lock()
        Self.captured.append(CapturedRequest(url: request.url, body: body, timeout: request.timeoutInterval, authorization: request.value(forHTTPHeaderField: "Authorization")))
        let (status, text, delay) = Self.reply(Self.captured.count)
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(text.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

final class ConfirmationTests: XCTestCase {
    private var suite: String!
    private var preferences: UserDefaults!
    private var session: URLSession!
    private var sdk: Codefluence!
    override func setUp() {
        suite = "codefluence-sdk-tests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockConfirmationProtocol.self]
        session = URLSession(configuration: configuration)
        sdk = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session)
        MockConfirmationProtocol.reset()
        MockConfirmationProtocol.reply = { _ in (200, "{\"leadId\":\"lead-fixture\"}", 0) }
    }
    override func tearDown() {
        session.invalidateAndCancel()
        preferences.removePersistentDomain(forName: suite)
        sdk = nil; session = nil; preferences = nil
    }

    func testUnconfiguredConfirmationAndRetryFailWithoutAnyNetworkOrFallbackHost() {
        sdk = Codefluence(preferences: preferences, session: session)
        let completed = expectation(description: "configuration is required")
        sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { first in
            XCTAssertTrue(Thread.isMainThread)
            switch first {
            case .success: XCTFail("unconfigured confirmation succeeded")
            case .failure(let error):
                XCTAssertEqual((error as NSError).code, 11)
                XCTAssertTrue(error.localizedDescription.contains("configure"))
            }
            // Configuration failure must preserve the explicit Yes and retry identity.
            XCTAssertTrue(self.preferences.bool(forKey: "codefluence.accepted"))
            XCTAssertEqual(self.preferences.string(forKey: "codefluence.pendingToken"), "accepted-token")
            XCTAssertEqual(self.preferences.string(forKey: "codefluence.pendingAppUserId"), "customer")
            self.sdk.retryPendingConfirmation { retry in
                if case .success = retry { XCTFail("unconfigured retry succeeded") }
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
    }

    func testExplicitLocalHTTPHostIsUsedExactlyWithoutAProductionFallback() {
        let host = URL(string: "http://127.0.0.1:39991")!
        sdk = Codefluence(publicKey: "pk_fixture", apiHost: host, preferences: preferences, session: session)
        let completed = expectation(description: "explicit development host")
        sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { result in
            XCTAssertEqual(try? result.get(), "lead-fixture")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(MockConfirmationProtocol.requests.count, 1)
        XCTAssertEqual(MockConfirmationProtocol.requests.first?.url?.absoluteString, "http://127.0.0.1:39991/track/confirm")
    }

    @MainActor
    func testAutoConfirmAttributesRestoredTokenWithoutPresentingAConfirmationSheet() {
        let completed = expectation(description: "automatic attribution")
        sdk.autoConfirmIfAvailable(appUserId: "customer", clickToken: "auto-token") { result in
            XCTAssertEqual(try? result.get(), "lead-fixture")
            XCTAssertTrue(self.preferences.bool(forKey: "codefluence.accepted"))
            XCTAssertEqual(self.preferences.string(forKey: "codefluence.confirmedLeadId"), "lead-fixture")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(MockConfirmationProtocol.requests.count, 1)
        let payload = try? JSONSerialization.jsonObject(with: MockConfirmationProtocol.requests[0].body) as? [String: String]
        XCTAssertEqual(payload?["clickToken"], "auto-token")
        XCTAssertEqual(payload?["appUserId"], "customer")
        XCTAssertEqual(payload?["build"], expectedBuild)
    }

    /// 서버가 토큰이나 공개 키를 거절하면(401) 원인을 짐작할 수 있도록 상태 코드를 메시지에 남긴다.
    @MainActor
    func testRejectedConfirmationReportsTheHTTPStatus() {
        MockConfirmationProtocol.reply = { _ in (401, "{\"error\":\"invalid_click_token\"}", 0) }
        let completed = expectation(description: "rejected")
        sdk.autoConfirmIfAvailable(appUserId: "customer", clickToken: "truncated-token") { result in
            guard case .failure(let error) = result else { return XCTFail("expected failure") }
            XCTAssertTrue(error.localizedDescription.contains("401"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.lowercased().contains("rejected"), error.localizedDescription)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    @MainActor
    func testAutoConfirmWithoutTokenMarksNormalStartWithoutARequest() {
        let completed = expectation(description: "automatic unattributed start")
        sdk.autoConfirmIfAvailable(appUserId: "customer", clickToken: "") { result in
            XCTAssertNil(try? result.get())
            XCTAssertTrue(self.preferences.bool(forKey: "codefluence.noTokenAtLaunch"))
            XCTAssertFalse(self.preferences.bool(forKey: "codefluence.accepted"))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
    }

    @MainActor
    func testAutoConfirmRejectsAConfirmedLeadForADifferentCustomer() {
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(true, forKey: "codefluence.accepted")
        preferences.set("lead-fixture", forKey: "codefluence.confirmedLeadId")
        preferences.set("original-customer", forKey: "codefluence.confirmedAppUserId")
        let completed = expectation(description: "different customer rejected")
        sdk.autoConfirmIfAvailable(appUserId: "other-customer", clickToken: "ignored") { result in
            if case .success = result { XCTFail("a lead was reused for another customer") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
    }

    @MainActor
    func testAutoConfirmRejectsBlankCustomerBeforeCreatingNoAttributionDecision() {
        let completed = expectation(description: "blank customer rejected")
        sdk.autoConfirmIfAvailable(appUserId: "", clickToken: "auto-token") { result in
            if case .success = result { XCTFail("blank customer was accepted") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertFalse(self.preferences.bool(forKey: "codefluence.decisionMade"))
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
    }

    func testInvalidHostOrBlankKeyFailsBeforeAnyNetworkRequest() {
        sdk = Codefluence(publicKey: " ", apiHost: URL(string: "file:///tmp/codefluence")!, preferences: preferences, session: session)
        let completed = expectation(description: "invalid configuration rejected")
        sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { result in
            switch result {
            case .success: XCTFail("invalid SDK configuration succeeded")
            case .failure(let error): XCTAssertEqual((error as NSError).code, 11)
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
        XCTAssertEqual(preferences.string(forKey: "codefluence.pendingToken"), "accepted-token")
        XCTAssertEqual(preferences.string(forKey: "codefluence.pendingAppUserId"), "customer")
    }

    func testApiHostMustBeAnOriginWithoutCredentialsPathQueryOrFragment() {
        for value in [
            "https://user:pass@sdk-test.invalid",
            "https://sdk-test.invalid/tenant",
            "https://sdk-test.invalid?token=secret",
            "https://sdk-test.invalid/#fragment"
        ] {
            preferences.removePersistentDomain(forName: suite)
            sdk = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: value)!, preferences: preferences, session: session)
            let completed = expectation(description: "reject \(value)")
            sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { result in
                if case .success = result { XCTFail("non-origin host was accepted: \(value)") }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 2)
        }
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
    }

    func testSecretKeyCannotBeSentByTheSDK() {
        sdk = Codefluence(publicKey: "sk_live_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session)
        let completed = expectation(description: "secret key rejected")
        sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { result in
            if case .success = result { XCTFail("secret key was accepted") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
        XCTAssertEqual(preferences.string(forKey: "codefluence.pendingToken"), "accepted-token")
    }

    @MainActor
    func testSoftNoTokenRestoresOnlyThroughHandleAfterRestart() async throws {
        XCTAssertEqual(sdk.prepareConfirmation(for: nil), .noAttribution)
        XCTAssertFalse(preferences.bool(forKey: "codefluence.decisionMade"))
        XCTAssertTrue(preferences.bool(forKey: "codefluence.noTokenAtLaunch"))
        let restarted = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session)
        XCTAssertEqual(restarted.prepareConfirmation(for: "arbitrary-token"), .noAttribution)
        XCTAssertTrue(restarted.handle(url: URL(string: "fixture://referral?cf_click_token=click.product.4102444800.signature")!))
        let lead: String? = try await withCheckedThrowingContinuation { continuation in
            restarted.autoConfirmIfAvailable(appUserId: "customer") { continuation.resume(with: $0) }
        }
        XCTAssertEqual(lead, "lead-fixture")
        let captured = try XCTUnwrap(MockConfirmationProtocol.requests.first)
        let payload = try JSONSerialization.jsonObject(with: captured.body) as! [String: String]
        XCTAssertEqual(payload["launchKind"], "later")
        XCTAssertTrue(restarted.handle(url: URL(string: "fixture://referral?cf_click_token=other.product.4102444800.signature")!))
        XCTAssertEqual(MockConfirmationProtocol.requests.count, 1)
    }

    @MainActor
    func testNullLeadReturnsToSoftStateWithoutRetry() async throws {
        _ = sdk.prepareConfirmation(for: nil)
        MockConfirmationProtocol.reply = { _ in (200, "{\"leadId\":null,\"reason\":\"existing_users_not_included\"}", 0) }
        _ = sdk.handle(url: URL(string: "fixture://referral?cf_click_token=click.product.4102444800.signature")!)
        let lead: String? = try await withCheckedThrowingContinuation { continuation in
            sdk.autoConfirmIfAvailable(appUserId: "customer") { continuation.resume(with: $0) }
        }
        XCTAssertNil(lead)
        XCTAssertFalse(preferences.bool(forKey: "codefluence.decisionMade"))
        XCTAssertFalse(preferences.bool(forKey: "codefluence.accepted"))
        XCTAssertNil(preferences.string(forKey: "codefluence.pendingToken"))
        XCTAssertEqual(preferences.bool(forKey: "codefluence.noTokenAtLaunch"), true)
        XCTAssertEqual(sdk.prepareConfirmation(for: nil), .noAttribution)
    }

    @MainActor
    func testHandlePreservesExplicitDeclineAndPendingIdentity() {
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(false, forKey: "codefluence.accepted")
        XCTAssertTrue(sdk.handle(url: URL(string: "fixture://referral?cf_click_token=click.product.4102444800.signature")!))
        XCTAssertNil(preferences.string(forKey: "codefluence.clickToken"))
        XCTAssertEqual(sdk.prepareConfirmation(for: "click.product.4102444800.signature"), .skip)
        preferences.removeObject(forKey: "codefluence.decisionMade")
        preferences.set("pending", forKey: "codefluence.pendingAppUserId")
        preferences.set("original", forKey: "codefluence.clickToken")
        _ = sdk.handle(url: URL(string: "fixture://referral?cf_click_token=other.product.4102444800.signature")!)
        XCTAssertEqual(preferences.string(forKey: "codefluence.clickToken"), "original")
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
    }

    func testBlankTokenMakesNoAttributionDecisionWithoutARequest() {
        XCTAssertEqual(sdk.prepareConfirmation(for: " \n"), .noAttribution)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
    }

    func testLateEmptyRestorationPreservesAcceptedPendingIdentity() {
        MockConfirmationProtocol.reply = { _ in (200, "{\"leadId\":\"lead-fixture\"}", 0.1) }
        let finished = expectation(description: "accepted request finishes")
        sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { result in
            XCTAssertEqual(try? result.get(), "lead-fixture")
            finished.fulfill()
        }
        XCTAssertEqual(sdk.prepareConfirmation(for: nil), .skip)
        XCTAssertTrue(preferences.bool(forKey: "codefluence.accepted"))
        XCTAssertEqual(preferences.string(forKey: "codefluence.pendingToken"), "accepted-token")
        XCTAssertEqual(preferences.string(forKey: "codefluence.pendingAppUserId"), "customer")
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(sdk.prepareConfirmation(for: nil), .skip)
        XCTAssertEqual(preferences.string(forKey: "codefluence.confirmedLeadId"), "lead-fixture")
        XCTAssertEqual(MockConfirmationProtocol.requests.count, 1)
    }

    func testPartialStoredDecisionsCannotBeOverwrittenByNoToken() {
        for (key, value) in [("accepted", true as Any), ("pendingToken", "token" as Any),
                             ("pendingAppUserId", "customer" as Any), ("confirmedLeadId", "lead" as Any)] {
            preferences.removePersistentDomain(forName: suite)
            preferences.set(value, forKey: "codefluence.\(key)")
            XCTAssertEqual(sdk.prepareConfirmation(for: nil), .skip)
            XCTAssertNil(preferences.object(forKey: "codefluence.decisionMade"))
            XCTAssertNotNil(preferences.object(forKey: "codefluence.\(key)"))
        }
    }

    func testConfirmationCopyUsesKoreanOnlyForKoreanLanguage() {
        for identifier in ["ko", "ko-KR", "ko_US"] {
            let copy = ConfirmationCopy(languageIdentifier: identifier)
            XCTAssertEqual(copy.title, "이 소개로 시작할까요?")
            XCTAssertEqual(copy.message, "이 소개 링크를 결제 귀속에 사용합니다.")
            XCTAssertEqual(copy.yes, "예")
            XCTAssertEqual(copy.no, "아니오")
        }
        for identifier in ["en", "en-KR", "ja-JP", "fr-FR", ""] {
            let copy = ConfirmationCopy(languageIdentifier: identifier)
            XCTAssertEqual(copy.title, "Start with this referral?")
            XCTAssertEqual(copy.message, "Use this referral link to attribute your purchases.")
            XCTAssertEqual(copy.yes, "Yes")
            XCTAssertEqual(copy.no, "No")
        }
    }

    func testDeclinedConfirmationCannotSendOrRetryEvenWithPendingValues() {
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(false, forKey: "codefluence.accepted")
        preferences.set("old-token", forKey: "codefluence.pendingToken")
        preferences.set("customer", forKey: "codefluence.pendingAppUserId")
        let denied = expectation(description: "declined")
        let retry = expectation(description: "retry denied")
        sdk.confirm(clickToken: "new-token", appUserId: "customer") { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("declined confirmation succeeded") }
            denied.fulfill()
        }
        sdk.retryPendingConfirmation { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("declined retry succeeded") }
            retry.fulfill()
        }
        wait(for: [denied, retry], timeout: 2)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
        XCTAssertFalse(preferences.bool(forKey: "codefluence.accepted"))
    }

    func testAcceptedFailureRetriesIdenticalPayloadAndCannotOverwriteIdentity() {
        MockConfirmationProtocol.reply = { count in count == 1 ? (503, "{}", 0) : (200, "{\"leadId\":\"lead-fixture\"}", 0) }
        let completed = expectation(description: "same accepted request retried")
        sdk.confirm(clickToken: "signed-fixture-token", appUserId: "stable-customer") { first in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = first { XCTFail("503 succeeded") }
            self.sdk.confirm(clickToken: "other-token", appUserId: "other-customer") { replacement in
                if case .success = replacement { XCTFail("pending identity replaced") }
                self.sdk.retryPendingConfirmation { retried in
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertEqual(try? retried.get(), "lead-fixture")
                    completed.fulfill()
                }
            }
        }
        wait(for: [completed], timeout: 3)
        let requests = MockConfirmationProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].body, requests[1].body)
        let payload = try? JSONSerialization.jsonObject(with: requests[0].body) as? [String: String]
        XCTAssertEqual(payload?["clickToken"], "signed-fixture-token")
        XCTAssertEqual(payload?["appUserId"], "stable-customer")
        XCTAssertEqual(requests[0].timeout, 5)
        XCTAssertEqual(requests[0].authorization, "Bearer pk_fixture")
        XCTAssertNil(preferences.string(forKey: "codefluence.pendingToken"))
    }

    func testMalformedSuccessRetainsPendingAndCompletedRetrySendsNothing() {
        MockConfirmationProtocol.reply = { count in count == 1 ? (200, "{\"leadId\":\"  \"}", 0) : (200, "{\"leadId\":\"lead-fixture\"}", 0) }
        let completed = expectation(description: "invalid success then completed")
        sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { first in
            if case .success = first { XCTFail("empty lead ID succeeded") }
            XCTAssertEqual(self.preferences.string(forKey: "codefluence.pendingToken"), "accepted-token")
            self.sdk.retryPendingConfirmation { second in
                XCTAssertEqual(try? second.get(), "lead-fixture")
                self.sdk.retryPendingConfirmation { extra in
                    if case .success = extra { XCTFail("completed retry succeeded") }
                    completed.fulfill()
                }
            }
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(MockConfirmationProtocol.requests.count, 2)
    }

    func testOverlappingConfirmationCallsProduceOneRequest() {
        MockConfirmationProtocol.reply = { _ in (200, "{\"leadId\":\"lead-fixture\"}", 0.1) }
        let callbacks = expectation(description: "both callbacks")
        callbacks.expectedFulfillmentCount = 2
        var successes = 0
        for _ in 0..<2 {
            sdk.confirm(clickToken: "accepted-token", appUserId: "customer") { result in
                XCTAssertTrue(Thread.isMainThread)
                if case .success = result { successes += 1 }
                callbacks.fulfill()
            }
        }
        wait(for: [callbacks], timeout: 3)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(MockConfirmationProtocol.requests.count, 1)
    }

    func testPromptAndRequestAdmissionAreExclusiveUnderContention() {
        let gate = ConfirmationGate()
        let countLock = NSLock()
        var prompts = 0, requests = 0
        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            let prompt = gate.beginPrompt()
            let request = gate.beginRequest()
            countLock.lock()
            if prompt { prompts += 1 }
            if request { requests += 1 }
            countLock.unlock()
        }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(requests, 1)
        gate.endPrompt(); gate.endRequest()
        XCTAssertTrue(gate.beginPrompt())
        XCTAssertTrue(gate.beginRequest())
    }
}

#if canImport(UIKit)
import UIKit

private struct MockPasteboardReader: Codefluence.PasteboardReader {
    var detected: Bool
    var string: String?
    func containsProbableWebURL() async throws -> Bool { detected }
}

extension ConfirmationTests {
    @MainActor
    func testClipboardReadsOnlyAfterProbableWebURLDetectionAndRequiresSignedShape() async {
        let valid = "https://sdk-test.invalid/t/click.product.4102444800.signature_01"
        let noPattern = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session, pasteboard: MockPasteboardReader(detected: false, string: valid))
        let noPatternToken = await noPattern.restoreReferralTokenAsync()
        XCTAssertNil(noPatternToken)
        let invalid = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session, pasteboard: MockPasteboardReader(detected: true, string: "https://sdk-test.invalid/t/raw-token"))
        let invalidToken = await invalid.restoreReferralTokenAsync()
        XCTAssertNil(invalidToken)
        let accepted = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session, pasteboard: MockPasteboardReader(detected: true, string: valid))
        let acceptedToken = await accepted.restoreReferralTokenAsync()
        XCTAssertEqual(acceptedToken, "click.product.4102444800.signature_01")
    }
}

extension ConfirmationTests {
    /// 호스트 앱이 토큰을 따로 넘기지 않아도(`clickToken: nil`), 랜딩이 복사한 소개 정보를
    /// 클립보드에서 복원해 자동 귀속한다. 복사 안 한 설치는 요청 없이 일반 시작으로 기록한다.
    @MainActor
    func testAutoConfirmRestoresTheTokenFromTheClipboardWhenNoTokenIsPassed() async {
        let valid = "https://sdk-test.invalid/t/click.product.4102444800.signature_01"
        let instance = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session, pasteboard: MockPasteboardReader(detected: true, string: valid))
        let leadId: String? = await withCheckedContinuation { continuation in
            instance.autoConfirmIfAvailable(appUserId: "customer") { result in continuation.resume(returning: try? result.get()) }
        }
        XCTAssertEqual(leadId, "lead-fixture")
        let payload = try? JSONSerialization.jsonObject(with: MockConfirmationProtocol.requests[0].body) as? [String: String]
        XCTAssertEqual(payload?["clickToken"], "click.product.4102444800.signature_01")
    }

    @MainActor
    func testAutoConfirmWithoutTokenAndWithoutAClipboardPatternSendsNothing() async {
        let valid = "https://sdk-test.invalid/t/click.product.4102444800.signature_01"
        let instance = Codefluence(publicKey: "pk_fixture", apiHost: URL(string: "https://sdk-test.invalid")!, preferences: preferences, session: session, pasteboard: MockPasteboardReader(detected: false, string: valid))
        let leadId: String? = await withCheckedContinuation { continuation in
            instance.autoConfirmIfAvailable(appUserId: "customer") { result in continuation.resume(returning: try? result.get()) }
        }
        XCTAssertNil(leadId)
        XCTAssertTrue(MockConfirmationProtocol.requests.isEmpty)
        XCTAssertTrue(preferences.bool(forKey: "codefluence.noTokenAtLaunch"))
    }
}
#endif
