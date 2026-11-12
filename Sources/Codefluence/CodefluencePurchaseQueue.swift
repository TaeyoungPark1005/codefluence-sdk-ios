import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 서버가 아직 받지 않은 구매 보고 하나(0.2.2). 전송에 필요한 최소 정보만 담는다:
/// Apple 서명 거래 JWS와 재시도 상태. 가격·사용자 정보는 저장하지 않는다(서버가 JWS에서 다시 읽는다).
struct QueuedPurchase: Codable, Equatable {
    /// 중복 방지 키. JWS 본문의 `transactionId`(스토어 목록의 거래 ID와 같은 값), 읽을 수 없으면 JWS 해시.
    let key: String
    let jws: String
    /// 처음 큐에 넣은 시각(초). 90일이 지나면 버린다.
    let enqueuedAt: TimeInterval
    /// 지금까지 보낸 횟수.
    var attempts: Int
    /// 이 시각(초) 전에는 자동으로 다시 보내지 않는다.
    var nextAttemptAt: TimeInterval
}

/// 구매 보고 응답 분류. 확인(confirm) 큐와 다르다: 409(`credential_missing`, 개발자가 결제 조회 키를 아직 등록하지 않음)는
/// 키가 등록되면 받아들여지므로 재시도 대상이고, 401·403(키 폐기)은 새 키가 담긴 앱 업데이트를 기다리며 긴 간격으로 보존한다.
enum PurchaseReportOutcome: Equatable {
    case accepted   // 2xx. 큐에서 지우고 보고 완료로 기록한다.
    case retry      // 네트워크 오류·408·409·429·5xx. backoff로 다시 보낸다.
    case retryLater // 401·403. 긴 간격(하루)으로 보존한다.
    case drop       // 400·404·422 등 영구 거절. 큐에서 지운다(스토어 목록에 남는 거래는 다음 목록 읽기 때 다시 보내진다).

    static func forStatus(_ status: Int?) -> PurchaseReportOutcome {
        guard let status else { return .retry }
        switch status {
        case 200..<300: return .accepted
        case 401, 403: return .retryLater
        case 408, 409, 429: return .retry
        case 500...599: return .retry
        case 400..<500: return .drop
        default: return .retry
        }
    }
}

/// 큐의 순수 규칙(상한·만료·중복). 저장과 전송은 `Codefluence`가 한다.
enum PurchaseQueueRules {
    static let maxRecords = 100
    static let maxAge: TimeInterval = 90 * 24 * 3600
    /// 401·403 뒤 다음 자동 시도까지의 간격.
    static let revokedKeyInterval: TimeInterval = 24 * 3600
    /// 구매 큐 backoff: 30초 시작·2배·상한 6시간·full jitter. 횟수가 아니라 90일 만료로 멈춘다.
    static let backoff = CodefluenceBackoffPolicy(base: 30, factor: 2, cap: 6 * 3600, maxAttempts: Int.max)

    static func pruned(_ records: [QueuedPurchase], now: TimeInterval) -> [QueuedPurchase] {
        let fresh = records.filter { now - $0.enqueuedAt < maxAge }
        return Array(fresh.sorted { $0.enqueuedAt < $1.enqueuedAt }.suffix(maxRecords))
    }

    /// 같은 키가 이미 있거나 보고가 끝난 거래면 그대로 둔다. 새 거래는 바로 보낼 수 있는 상태로 넣는다.
    static func enqueue(_ records: [QueuedPurchase], key: String, jws: String, now: TimeInterval, reported: Set<String>) -> [QueuedPurchase] {
        guard !reported.contains(key), !records.contains(where: { $0.key == key }) else { return pruned(records, now: now) }
        return pruned(records + [QueuedPurchase(key: key, jws: jws, enqueuedAt: now, attempts: 0, nextAttemptAt: now)], now: now)
    }

    /// 실패한 시도 뒤 다음 시도 시각.
    static func nextAttempt(after outcome: PurchaseReportOutcome, attempts: Int, now: TimeInterval, jitter: Double) -> TimeInterval {
        switch outcome {
        case .retryLater: return now + revokedKeyInterval
        default: return now + backoff.delay(forAttempt: attempts + 1, jitter: jitter)
        }
    }

    /// JWS 본문의 `transactionId`. 서명은 서버가 검증하므로 여기서는 중복 방지 키로만 읽는다.
    static func key(forJWS jws: String) -> String {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 3 {
            var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64.append("=") }
            if let data = Data(base64Encoded: base64),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let id = object["transactionId"] as? String, !id.isEmpty { return id }
                if let id = object["transactionId"] as? NSNumber { return id.stringValue }
            }
        }
        #if canImport(CryptoKit)
        return "sha256:" + SHA256.hash(data: Data(jws.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return "jws:" + String(jws.suffix(64))
        #endif
    }
}

/// 큐를 저장하는 곳. 기본은 백업에서 제외한 Application Support 파일이라 iCloud·기기 이전으로 다른 기기에 복제되지 않는다.
protocol PurchaseQueueStore: AnyObject {
    func load() -> [QueuedPurchase]
    func save(_ records: [QueuedPurchase])
}

/// 패키지 테스트와 파일을 쓸 수 없는 환경용.
final class InMemoryPurchaseQueueStore: PurchaseQueueStore {
    private var records: [QueuedPurchase] = []
    func load() -> [QueuedPurchase] { records }
    func save(_ records: [QueuedPurchase]) { self.records = records }
}

final class FilePurchaseQueueStore: PurchaseQueueStore {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("purchase-queue.json")
    }

    /// `Application Support/Codefluence/purchase-queue.json`. 디렉터리를 만들 수 없으면 nil(메모리 큐로 대신한다).
    static func makeDefault() -> FilePurchaseQueueStore? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return FilePurchaseQueueStore(directory: base.appendingPathComponent("Codefluence", isDirectory: true))
    }

    /// 첫 읽기 뒤에는 메모리 사본을 쓴다(호출은 `Codefluence.stateLock` 안에서만 일어난다).
    private var cache: [QueuedPurchase]?

    func load() -> [QueuedPurchase] {
        if let cache { return cache }
        let records = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([QueuedPurchase].self, from: $0) } ?? []
        cache = records
        return records
    }

    func save(_ records: [QueuedPurchase]) {
        cache = records
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try excludeFromBackup(directory)
            if records.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
                return
            }
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try JSONEncoder().encode(records).write(to: fileURL, options: options)
            try excludeFromBackup(fileURL)
        } catch {
            // 저장 실패가 결제 흐름을 막으면 안 된다. 이번 실행의 메모리 상태로 계속하고 다음 저장에서 다시 시도한다.
            NSLog("[Codefluence] purchase queue could not be saved: %@", String(describing: type(of: error)))
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}
