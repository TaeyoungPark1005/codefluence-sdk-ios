import XCTest
import Foundation
@testable import Codefluence

// 0.2.2 미전송 구매 영속 큐: 결제 직후 받은 거래를 기기에 저장하고 서버가 2xx로 받을 때까지 다시 보낸다.
final class QueueMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [(path: String, body: [String: Any])] = []
    static var reply: (String) -> Int? = { _ in 200 }
    static var requests: [(path: String, body: [String: Any])] { lock.lock(); defer { lock.unlock() }; return captured }
    static var purchaseBodies: [[String: Any]] { requests.filter { $0.path.hasSuffix("/track/purchase") }.map(\.body) }
    static func reset() { lock.lock(); captured = []; reply = { _ in 200 }; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
        }
        let path = request.url?.path ?? ""
        let object = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        Self.lock.lock(); Self.captured.append((path, object)); let status = Self.reply(path); Self.lock.unlock()
        guard let status else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((path.hasSuffix("/track/confirm") ? "{\"leadId\":\"lead-fixture\"}" : "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private struct Source: StoreTransactionSource {
    var appJWS: String?
    var transactions: [(transactionId: String, jws: String)] = []
    func appTransactionJWS() async -> String? { appJWS }
    func signedTransactions() async -> [(transactionId: String, jws: String)] { transactions }
}

private final class Timers {
    private let lock = NSLock()
    private var pending: [(TimeInterval, () -> Void)] = []
    var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return pending.map(\.0) }
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { lock.lock(); pending.append((delay, work)); lock.unlock() }
    func runNext() { lock.lock(); let work = pending.isEmpty ? nil : pending.removeFirst().1; lock.unlock(); work?() }
}

private final class Monitor: CodefluenceNetworkMonitor {
    var handler: (() -> Void)?
    func start(onSatisfied: @escaping () -> Void) { handler = onSatisfied }
    func cancel() { handler = nil }
}

/// Apple 서명 거래와 같은 모양(헤더.본문.서명)의 가짜 JWS. SDK는 본문의 transactionId만 중복 방지 키로 읽는다.
func fakeTransactionJWS(_ id: String) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["transactionId": id, "type": "Consumable"])
    let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJFUzI1NiJ9.\(encoded).c2lnbmF0dXJl"
}

final class PurchaseQueueTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: InMemoryPurchaseQueueStore!
    private var timers: Timers!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "purchase-queue-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = InMemoryPurchaseQueueStore()
        timers = Timers()
        QueueMockProtocol.reset()
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func sdk(source: StoreTransactionSource = Source(appJWS: "signed-app-transaction"), store: PurchaseQueueStore? = nil, monitor: CodefluenceNetworkMonitor? = nil) -> Codefluence {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueMockProtocol.self]
        let instance = Codefluence(publicKey: "pk_test", apiHost: URL(string: "https://api.example.test")!, preferences: defaults, session: URLSession(configuration: configuration))
        instance.transactionSource = source
        instance.purchaseQueueStore = store ?? self.store
        instance.purchaseClock = { [unowned self] in self.now }
        instance.injectRetryDependencies(jitter: { 0.5 }, scheduler: { [timers] delay, work in timers!.schedule(delay, work) }, monitor: monitor)
        return instance
    }
    private func referred() { defaults.set("lead-1", forKey: "codefluence.confirmedLeadId") }
    private func complete(_ instance: Codefluence, _ jws: String) -> Int {
        let done = expectation(description: "purchaseCompleted")
        var count = -1
        instance.purchaseCompleted(jws: jws) { count = (try? $0.get()) ?? -2; done.fulfill() }
        wait(for: [done], timeout: 5)
        return count
    }
    private func flush(_ instance: Codefluence) -> Int {
        let done = expectation(description: "flush")
        var count = -1
        instance.flushPurchaseQueue { count = (try? $0.get()) ?? -2; done.fulfill() }
        wait(for: [done], timeout: 5)
        return count
    }

    func testDirectTransactionIsSentRightAwayWithAppTransaction() {
        referred()
        let instance = sdk()
        XCTAssertEqual(complete(instance, fakeTransactionJWS("2000000111")), 1)
        let body = QueueMockProtocol.purchaseBodies.first
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 1)
        XCTAssertEqual(body?["signedTransaction"] as? String, fakeTransactionJWS("2000000111"))
        XCTAssertEqual(body?["appTransaction"] as? String, "signed-app-transaction")
        XCTAssertEqual(body?["build"] as? String, Codefluence.build)
        XCTAssertNil(body?["appTransactionJws"])
        XCTAssertTrue(instance.queuedPurchases().isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "codefluence.reportedTransactionIds"), ["2000000111"])
    }

    func testAppTransactionFieldIsOmittedWhenUnavailable() {
        referred()
        let instance = sdk(source: Source(appJWS: nil))
        XCTAssertEqual(complete(instance, fakeTransactionJWS("1")), 1)
        XCTAssertNil(QueueMockProtocol.purchaseBodies.first?["appTransaction"])
    }

    func testQueuedPurchaseSurvivesARestartAndIsSentOnTheNextLaunch() throws {
        referred()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cf-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        QueueMockProtocol.reply = { _ in 503 }
        XCTAssertEqual(complete(sdk(store: FilePurchaseQueueStore(directory: directory)), fakeTransactionJWS("tx-restart")), 0)
        // 다음 실행: 새 인스턴스·새 저장소 객체가 같은 파일을 읽는다. 스토어 목록에는 이 거래가 없다(소모성이 이미 finish됨).
        QueueMockProtocol.reply = { _ in 200 }
        let relaunched = sdk(source: Source(appJWS: nil, transactions: []), store: FilePurchaseQueueStore(directory: directory))
        XCTAssertEqual(relaunched.queuedPurchases().map(\.key), ["tx-restart"])
        now = now.addingTimeInterval(3600)
        let done = expectation(description: "launch report")
        var count = -1
        relaunched.reportPurchases { count = (try? $0.get()) ?? -2; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 2)
        XCTAssertTrue(relaunched.queuedPurchases().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("purchase-queue.json").path))
    }

    func testFileStoreIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cf-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = FilePurchaseQueueStore(directory: directory)
        file.save([QueuedPurchase(key: "k", jws: "j", enqueuedAt: 1, attempts: 0, nextAttemptAt: 1)])
        XCTAssertEqual(try file.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(FilePurchaseQueueStore(directory: directory).load().map(\.key), ["k"])
        let saved = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("price"))
    }

    func testOutcomeClassificationForPurchaseReports() {
        XCTAssertEqual(PurchaseReportOutcome.forStatus(200), .accepted)
        XCTAssertEqual(PurchaseReportOutcome.forStatus(nil), .retry)
        for status in [408, 409, 429, 500, 502, 503] { XCTAssertEqual(PurchaseReportOutcome.forStatus(status), .retry, "\(status)") }
        for status in [401, 403] { XCTAssertEqual(PurchaseReportOutcome.forStatus(status), .retryLater, "\(status)") }
        for status in [400, 404, 410, 422] { XCTAssertEqual(PurchaseReportOutcome.forStatus(status), .drop, "\(status)") }
    }

    func testCredentialMissingKeepsThePurchaseAndSchedulesARetry() {
        referred()
        QueueMockProtocol.reply = { _ in 409 }
        let instance = sdk()
        XCTAssertEqual(complete(instance, fakeTransactionJWS("tx-409")), 0)
        let queued = instance.queuedPurchases()
        XCTAssertEqual(queued.map(\.key), ["tx-409"])
        XCTAssertEqual(queued.first?.attempts, 1)
        // 30초 backoff × jitter 0.5 = 15초 뒤
        XCTAssertEqual(queued.first?.nextAttemptAt, now.timeIntervalSince1970 + 15)
        XCTAssertEqual(timers.delays, [15])
        // 개발자가 키를 등록한 뒤 예약된 재시도가 보낸다.
        QueueMockProtocol.reply = { _ in 200 }
        now = now.addingTimeInterval(15)
        timers.runNext()
        let sent = expectation(description: "retry sent")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { sent.fulfill() }
        wait(for: [sent], timeout: 2)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 2)
        XCTAssertTrue(instance.queuedPurchases().isEmpty)
    }

    func testNetworkFailureAndServerErrorsAreRetriedAfterBackoff() {
        referred()
        QueueMockProtocol.reply = { _ in nil }
        let instance = sdk()
        XCTAssertEqual(complete(instance, fakeTransactionJWS("tx-offline")), 0)
        QueueMockProtocol.reply = { _ in 500 }
        // backoff 전에는 보내지 않는다.
        XCTAssertEqual(flush(instance), 0)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 1)
        now = now.addingTimeInterval(15)
        XCTAssertEqual(flush(instance), 0)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 2)
        XCTAssertEqual(instance.queuedPurchases().first?.attempts, 2)
        // 두 번째 실패 뒤 ceiling 60초 × 0.5
        XCTAssertEqual(instance.queuedPurchases().first?.nextAttemptAt, now.timeIntervalSince1970 + 30)
    }

    func testPermanentRejectionRemovesThePurchase() {
        referred()
        QueueMockProtocol.reply = { _ in 422 }
        let instance = sdk()
        XCTAssertEqual(complete(instance, fakeTransactionJWS("tx-bad")), 0)
        XCTAssertTrue(instance.queuedPurchases().isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: "codefluence.reportedTransactionIds"))
        now = now.addingTimeInterval(86_400)
        XCTAssertEqual(flush(instance), 0)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 1)
    }

    func testRevokedKeyKeepsThePurchaseWithALongInterval() {
        referred()
        QueueMockProtocol.reply = { _ in 401 }
        let instance = sdk()
        XCTAssertEqual(complete(instance, fakeTransactionJWS("tx-401")), 0)
        XCTAssertEqual(instance.queuedPurchases().first?.nextAttemptAt, now.timeIntervalSince1970 + 86_400)
        now = now.addingTimeInterval(3600)
        XCTAssertEqual(flush(instance), 0)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 1)
        QueueMockProtocol.reply = { _ in 200 }
        now = now.addingTimeInterval(86_400)
        XCTAssertEqual(flush(instance), 1)
    }

    func testTheSameTransactionIsQueuedOnceAndAReportedOneIsNotQueuedAgain() {
        referred()
        QueueMockProtocol.reply = { _ in 503 }
        let instance = sdk()
        _ = complete(instance, fakeTransactionJWS("tx-dup"))
        _ = complete(instance, fakeTransactionJWS("tx-dup"))
        XCTAssertEqual(instance.queuedPurchases().count, 1)
        defaults.set(["tx-old"], forKey: "codefluence.reportedTransactionIds")
        XCTAssertEqual(complete(instance, fakeTransactionJWS("tx-old")), 0)
        XCTAssertEqual(instance.queuedPurchases().map(\.key), ["tx-dup"])
        // 스토어 목록에서 읽은 같은 거래도 큐에 한 번만 들어간다.
        let scanning = sdk(source: Source(appJWS: nil, transactions: [("tx-dup", fakeTransactionJWS("tx-dup"))]))
        let done = expectation(description: "scan")
        scanning.reportPurchases { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(scanning.queuedPurchases().count, 1)
    }

    func testQueueKeepsAtMostOneHundredRecordsForNinetyDays() {
        let start: TimeInterval = 1_000
        var records: [QueuedPurchase] = []
        for index in 0..<105 { records = PurchaseQueueRules.enqueue(records, key: "k\(index)", jws: "j\(index)", now: start + Double(index), reported: []) }
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.first?.key, "k5")
        let later = start + 90 * 86_400 + 50
        XCTAssertEqual(PurchaseQueueRules.pruned(records, now: later).first?.key, "k51")
    }

    func testJWSKeyIsTheTransactionIdOrAHashFallback() {
        XCTAssertEqual(PurchaseQueueRules.key(forJWS: fakeTransactionJWS("2000000999")), "2000000999")
        let fallback = PurchaseQueueRules.key(forJWS: "not-a-jws")
        XCTAssertTrue(fallback.hasPrefix("sha256:"))
        XCTAssertEqual(fallback, PurchaseQueueRules.key(forJWS: "not-a-jws"))
    }

    func testInstallWithoutAReferralQueuesAndSendsNothing() {
        let instance = sdk()
        XCTAssertEqual(complete(instance, fakeTransactionJWS("tx-organic")), 0)
        XCTAssertTrue(instance.queuedPurchases().isEmpty)
        XCTAssertTrue(QueueMockProtocol.requests.isEmpty)
    }

    func testPendingConfirmationHoldsThePurchaseUntilTheReferralIsConfirmed() {
        defaults.set(true, forKey: "codefluence.decisionMade")
        defaults.set(true, forKey: "codefluence.accepted")
        defaults.set("signed.token", forKey: "codefluence.pendingToken")
        defaults.set("customer", forKey: "codefluence.pendingAppUserId")
        let instance = sdk()
        XCTAssertEqual(complete(instance, fakeTransactionJWS("tx-early")), 0)
        XCTAssertTrue(QueueMockProtocol.purchaseBodies.isEmpty)
        XCTAssertEqual(instance.queuedPurchases().count, 1)
        // 확인이 끝나면(confirm 성공 뒤 reportPurchases가 돈다) 보낸다.
        let confirmed = expectation(description: "confirm")
        instance.retryPendingConfirmation { _ in confirmed.fulfill() }
        wait(for: [confirmed], timeout: 5)
        let sent = expectation(description: "report after confirm")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { sent.fulfill() }
        wait(for: [sent], timeout: 2)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 1)
        XCTAssertTrue(instance.queuedPurchases().isEmpty)
    }

    func testAbandonedReferralClearsTheQueue() {
        store.save([QueuedPurchase(key: "k", jws: "j", enqueuedAt: now.timeIntervalSince1970, attempts: 0, nextAttemptAt: 0)])
        let instance = sdk()
        XCTAssertEqual(flush(instance), 0)
        XCTAssertTrue(instance.queuedPurchases().isEmpty)
        XCTAssertTrue(QueueMockProtocol.requests.isEmpty)
    }

    func testNetworkRecoveryFlushesTheQueue() {
        referred()
        let monitor = Monitor()
        QueueMockProtocol.reply = { _ in nil }
        let instance = sdk(monitor: monitor)
        instance.startNetworkMonitorIfNeeded()
        _ = complete(instance, fakeTransactionJWS("tx-net"))
        QueueMockProtocol.reply = { _ in 200 }
        now = now.addingTimeInterval(60)
        monitor.handler?()
        let sent = expectation(description: "recovery")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { sent.fulfill() }
        wait(for: [sent], timeout: 2)
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.count, 2)
        XCTAssertTrue(instance.queuedPurchases().isEmpty)
    }

    func testStoreListTransactionsGoThroughTheQueueForAReferredInstall() {
        referred()
        QueueMockProtocol.reply = { _ in 503 }
        let instance = sdk(source: Source(appJWS: "app", transactions: [("tx-list", fakeTransactionJWS("tx-list"))]))
        let done = expectation(description: "scan")
        instance.reportPurchases { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(instance.queuedPurchases().map(\.key), ["tx-list"])
        XCTAssertEqual(QueueMockProtocol.purchaseBodies.first?["appTransaction"] as? String, "app")
    }
}

/// RevenueCat `StoreTransaction`처럼 `jwsRepresentation`을 Objective-C 속성으로만 노출하는 객체.
private final class FakeRevenueCatTransaction: NSObject {
    @objc let jwsRepresentation: String?
    init(_ jws: String?) { jwsRepresentation = jws }
}

final class RevenueCatTransactionTests: XCTestCase {
    func testReadsTheObjectiveCJWSPropertyWhenPresent() {
        XCTAssertEqual(Codefluence.jwsRepresentation(of: FakeRevenueCatTransaction(fakeTransactionJWS("rc-1"))), fakeTransactionJWS("rc-1"))
        XCTAssertNil(Codefluence.jwsRepresentation(of: FakeRevenueCatTransaction(nil)))
        XCTAssertNil(Codefluence.jwsRepresentation(of: NSObject()))
        XCTAssertNil(Codefluence.jwsRepresentation(of: nil))
    }

    func testStoreTransactionIsQueuedLikeADirectJWS() {
        let suite = "rc-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("lead-1", forKey: "codefluence.confirmedLeadId")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueMockProtocol.self]
        QueueMockProtocol.reset(); QueueMockProtocol.reply = { _ in 503 }
        let instance = Codefluence(publicKey: "pk_test", apiHost: URL(string: "https://api.example.test")!, preferences: defaults, session: URLSession(configuration: configuration))
        instance.injectRetryDependencies(scheduler: { _, _ in })
        let done = expectation(description: "rc")
        instance.purchaseCompleted(storeTransaction: FakeRevenueCatTransaction(fakeTransactionJWS("rc-2"))) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(instance.queuedPurchases().map(\.key), ["rc-2"])
    }
}
