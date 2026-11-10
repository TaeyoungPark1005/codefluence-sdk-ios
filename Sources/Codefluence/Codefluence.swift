import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public final class Codefluence {
    public static let shared = Codefluence()
    private var publicKey: String = ""
    private var apiHost: URL?
    private let stateLock = NSLock()
    private let gate = ConfirmationGate()
    private let preferences: UserDefaults
    private let session: URLSession

    // A3 automatic retry dependencies. Defaults use real time/jitter/monitor;
    // tests inject deterministic values. Guarded by `stateLock`.
    private var backoffPolicy = CodefluenceBackoffPolicy()
    private var jitterProvider: () -> Double = { Double.random(in: 0..<1) }
    private var scheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var networkMonitor: CodefluenceNetworkMonitor?
    private var monitorStarted = false
    private var retryScheduled = false
    #if canImport(UIKit)
    protocol PasteboardReader {
        func containsProbableWebURL() async throws -> Bool
        var string: String? { get }
    }
    struct SystemPasteboardReader: PasteboardReader {
        func containsProbableWebURL() async throws -> Bool {
            // The completion-handler form exists on every supported SDK; Xcode 27 dropped the async overload.
            try await withCheckedThrowingContinuation { continuation in
                UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                    continuation.resume(with: result.map { $0.contains(.probableWebURL) })
                }
            }
        }
        var string: String? { UIPasteboard.general.string }
    }
    private let pasteboard: PasteboardReader
    #endif
    private convenience init() {
        self.init(preferences: .standard, session: .shared)
        #if canImport(StoreKit)
        transactionSource = SystemStoreTransactionSource()
        #endif
    }
    /// Where App Store data comes from. Package tests inject a fake.
    var transactionSource: StoreTransactionSource = EmptyStoreTransactionSource()
    /// Upper bound for reading the AppTransaction before a confirmation is sent without it.
    var appTransactionTimeout: TimeInterval = 2.5
    /// One purchase report at a time; overlapping calls (launch, confirm, purchase callback) return 0.
    private var reportInFlight = false
    /// Host-provided stable customer ID for the one-call helper (`start`). Guarded by `stateLock`.
    private var appUserIdProvider: (() -> String?)?
    private var foregroundObserver: NSObjectProtocol?

    // Isolated storage/transport for package tests; not a public host API.
    init(preferences: UserDefaults, session: URLSession) {
        self.preferences = preferences
        self.session = session
        #if canImport(Network)
        self.networkMonitor = SystemNetworkMonitor()
        #endif
        #if canImport(UIKit)
        self.pasteboard = SystemPasteboardReader()
        #endif
    }

    #if canImport(UIKit)
    init(preferences: UserDefaults, session: URLSession, pasteboard: PasteboardReader) {
        self.preferences = preferences
        self.session = session
        #if canImport(Network)
        self.networkMonitor = SystemNetworkMonitor()
        #endif
        self.pasteboard = pasteboard
    }
    #endif

    convenience init(publicKey: String, apiHost: URL, preferences: UserDefaults, session: URLSession) {
        self.init(preferences: preferences, session: session)
        self.publicKey = publicKey
        self.apiHost = apiHost
    }

    #if canImport(UIKit)
    convenience init(publicKey: String, apiHost: URL, preferences: UserDefaults, session: URLSession, pasteboard: PasteboardReader) {
        self.init(preferences: preferences, session: session, pasteboard: pasteboard)
        self.publicKey = publicKey
        self.apiHost = apiHost
    }
    #endif

    public static func configure(publicKey: String, apiHost: URL) {
        shared.stateLock.lock()
        shared.publicKey = publicKey
        shared.apiHost = apiHost
        shared.stateLock.unlock()
        // A3: on app relaunch, resume any accepted-but-unfinished confirmation and
        // begin watching for connectivity recovery.
        shared.startNetworkMonitorIfNeeded()
        shared.resumePendingConfirmationIfNeeded()
        // Purchases made while the app was closed or by another purchase SDK are reported on launch.
        if shared.preferences.string(forKey: "codefluence.confirmedLeadId") != nil { shared.reportPurchases() }
    }

    /// SDK 버전. heartbeat가 서버에 보내 앱 버전별 신호 표에 나타납니다.
    public static let version = "0.1.3"

    /// Info.plist의 URL Types에 등록된 스킴. 테스트가 바꿉니다.
    var registeredURLSchemes: () -> [String] = {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }

    /// 서버가 받는 계약 그대로 보냅니다: `platform`은 필수, 증명이 없으면 `attestation` 키를 뺍니다(null은 400).
    func postHeartbeat(host: URL, key: String, appVersion: String?, sdkVersion: String, attestation: String?, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let url = URL(string: host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/sdk/heartbeat") else {
            completion(.failure(failure(11, "SDK is not configured"))); return
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "platform": "ios",
            "appVersion": appVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "sdkVersion": sdkVersion
        ]
        if let attestation { body["attestation"] = attestation }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request) { _, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure(self.failure(1, "No HTTP response"))); return }
            completion(.success(http.statusCode))
        }.resume()
    }

    /// 출시 전 설치 점검. 키 모양, 서버 접속과 키 유효성(heartbeat를 실제로 보내므로 대시보드에 첫 신호가 바로 뜹니다),
    /// 선택적으로 앱 URL 스킴 등록을 확인하고 항목별 통과·실패와 고칠 방법을 돌려줍니다. 결과는 콘솔에도 `[Codefluence]` 접두어로 찍습니다.
    /// 디버그 빌드에서 부르세요. 토큰·키 값은 어디에도 출력하지 않습니다.
    public func validate(urlScheme: String? = nil, completion: @escaping ([CodefluenceCheck]) -> Void) {
        stateLock.lock(); let host = apiHost; let key = publicKey; stateLock.unlock()
        var checks: [CodefluenceCheck] = []
        let configured = key.hasPrefix("pk_") && key.count > 3 && host != nil
        if configured {
            checks.append(CodefluenceCheck(name: "설정", passed: true, hint: "pk_ 공개 키와 서버 주소가 설정돼 있어요"))
        } else if key.hasPrefix("sk_") {
            checks.append(CodefluenceCheck(name: "설정", passed: false, hint: "비밀 키(sk_)가 앱에 들어 있어요. 앱에는 pk_ 공개 키만 넣고 sk_ 키는 폐기하세요"))
        } else {
            checks.append(CodefluenceCheck(name: "설정", passed: false, hint: "pk_ 공개 키와 서버 주소(https://…)를 start 또는 configure에 넣으세요. 빌드 설정 값이 비어 있거나 xcconfig의 //에서 잘렸는지 확인하세요"))
        }
        let finish: () -> Void = { [self] in
            if let urlScheme {
                let registered = registeredURLSchemes().contains(where: { $0.caseInsensitiveCompare(urlScheme) == .orderedSame })
                checks.append(CodefluenceCheck(name: "URL 스킴", passed: registered, hint: registered
                    ? "\(urlScheme):// 스킴이 앱에 등록돼 있어요"
                    : "앱의 URL Types에 스킴 \(urlScheme)을 등록하세요(Info.plist CFBundleURLTypes). 대시보드 제품 화면의 「앱 열기 스킴」에도 같은 값을 저장해야 소개 링크가 앱을 열어요"))
            }
            for check in checks { NSLog("[Codefluence] %@ %@: %@", check.passed ? "✓" : "✗", check.name, check.hint) }
            DispatchQueue.main.async { completion(checks) }
        }
        guard configured, let host else { finish(); return }
        postHeartbeat(host: host, key: key, appVersion: nil, sdkVersion: Codefluence.version, attestation: nil) { result in
            switch result {
            case .failure:
                checks.append(CodefluenceCheck(name: "서버와 키", passed: false, hint: "서버에 연결하지 못했어요. 서버 주소(\(host.host ?? "?"))와 기기의 네트워크, 로컬 서버라면 ATS 설정을 확인하세요"))
            case .success(let status):
                switch status {
                case 200..<300: checks.append(CodefluenceCheck(name: "서버와 키", passed: true, hint: "서버가 키를 받아들였고 첫 신호가 도착했어요"))
                case 401, 403: checks.append(CodefluenceCheck(name: "서버와 키", passed: false, hint: "서버가 키를 거절했어요. pk_ 공개 키가 이 제품의 키가 맞는지, 폐기되지 않았는지 대시보드 「키와 결제 알림」에서 확인하세요"))
                case 422: checks.append(CodefluenceCheck(name: "서버와 키", passed: false, hint: "키의 제품 플랫폼이 iOS가 아니에요. iOS 제품의 pk_ 키를 쓰세요(Android 제품 키와 섞이지 않았는지 확인)"))
                default: checks.append(CodefluenceCheck(name: "서버와 키", passed: false, hint: "서버가 \(status)을 돌려줬어요. 잠시 뒤 다시 시도하고 계속되면 서버 주소를 확인하세요"))
                }
            }
            finish()
        }
    }

    // MARK: - One-call helper

    /// Sets the SDK up in one call. Replaces the separate `configure`, launch confirmation,
    /// deep-link and purchase-report wiring, and gets their ordering right:
    ///
    /// - the deep link may arrive before or after `start`, and before the host knows its
    ///   customer ID; the token is kept and confirmed as soon as `appUserId` returns a value;
    /// - a launch without any link does not record "no attribution" until `launchGrace`
    ///   seconds passed, so a cold-start deep link is never lost to that race.
    ///
    /// `appUserId` returns the host's stable customer ID, or nil while it is not known yet
    /// (for example before the purchase SDK is configured). Call `resume()` once it is.
    @MainActor
    public static func start(publicKey: String, apiHost: URL, appUserId: @escaping () -> String?) {
        configure(publicKey: publicKey, apiHost: apiHost)
        shared.begin(appUserId: appUserId)
    }

    @MainActor
    func begin(appUserId: @escaping () -> String?, launchGrace: TimeInterval = 1.0,
               scheduler: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        stateLock.lock(); appUserIdProvider = appUserId; stateLock.unlock()
        #if canImport(UIKit)
        heartbeat() // 하루 한 번. 대시보드의 「SDK 신호」가 첫 실행에 바로 뜬다.
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
        #endif
        let run: (TimeInterval, @escaping () -> Void) -> Void = scheduler ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        run(launchGrace) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resume() } }
        }
    }

    /// Hand every incoming URL to this. Returns true when it was a referral link for this app
    /// (the token is saved and confirmed as soon as the customer ID is known).
    @MainActor
    @discardableResult
    public func handle(url: URL) -> Bool {
        var token = urlToken(url)
        if token == nil, url.host == "referral" || url.host == "" {
            token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "cf_click_token" || $0.name == "codefluence_click_token" })?.value
        }
        guard let token, token.range(of: #"^[^./?#]+\.[^./?#]+\.[0-9]+\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return false }
        stateLock.lock()
        let alreadyDecided = preferences.bool(forKey: "codefluence.decisionMade")
        let locked = alreadyDecided || preferences.bool(forKey: "codefluence.accepted") || preferences.object(forKey: "codefluence.pendingToken") != nil || preferences.object(forKey: "codefluence.pendingAppUserId") != nil || preferences.object(forKey: "codefluence.confirmedLeadId") != nil
        if !locked {
            preferences.set(token, forKey: "codefluence.clickToken")
            if preferences.bool(forKey: "codefluence.noTokenAtLaunch") { preferences.set(token, forKey: "codefluence.laterLinkToken") }
        }
        let confirmed = preferences.string(forKey: "codefluence.confirmedLeadId") != nil
        let savedToken = preferences.string(forKey: "codefluence.clickToken")
        stateLock.unlock()
        // 이미 소개로 확인된 설치가 다른 링크를 다시 열었다: 첫 소개자는 그대로 두고, 서버에 "이 링크를 열었다"만 알린다.
        // 소모성(일회성) 재결제를 결제 직전에 연 링크의 크리에이터에게 귀속하는 근거다.
        if confirmed, token != savedToken { reportReferralTouch(token: token) }
        resume()
        return true
    }

    /// 확인된 설치가 다른 크리에이터의 링크를 다시 열었음을 `/track/touch`로 알린다. 서버가 받아들였거나 영구 오류로 거절한 링크는 다시 보내지 않고,
    /// 일시 오류·연결 실패는 같은 링크를 다시 열 때 다시 시도한다. 응답은 기록 여부만 알려 주며 앱 동작에는 영향이 없다.
    private func reportReferralTouch(token: String) {
        stateLock.lock()
        let host = apiHost; let key = publicKey
        let appUserId = preferences.string(forKey: "codefluence.confirmedAppUserId")
        let installToken = preferences.string(forKey: "codefluence.purchaseAccountToken")
        let reported = preferences.stringArray(forKey: "codefluence.touchedTokens") ?? []
        stateLock.unlock()
        guard let host, key.hasPrefix("pk_"), let appUserId, let installToken, !reported.contains(token),
              let url = URL(string: host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/track/touch") else { return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["clickToken": token, "appUserId": appUserId, "purchaseAccountToken": installToken])
        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self, let status = (response as? HTTPURLResponse)?.statusCode else { return }
            guard (200..<300).contains(status) || [400, 401, 403, 404, 409, 422].contains(status) else { return }
            self.stateLock.lock()
            var list = self.preferences.stringArray(forKey: "codefluence.touchedTokens") ?? []
            list.append(token); self.preferences.set(Array(list.suffix(20)), forKey: "codefluence.touchedTokens")
            self.stateLock.unlock()
        }.resume()
    }

    /// Confirms a saved or copied referral and reports purchases, once the customer ID is known.
    /// Safe to call any time: when `start`'s `appUserId` returns nil it does nothing, and it
    /// never records "no attribution" for that reason. Also runs whenever the app becomes active.
    @MainActor
    public func resume() {
        stateLock.lock(); let provider = appUserIdProvider; stateLock.unlock()
        guard let id = provider?(), !id.isEmpty else { return }
        autoConfirmIfAvailable(appUserId: id) { [weak self] _ in self?.reportIfReferred() }
    }

    /// Call after a purchase succeeds, with any purchase SDK. Reports the store transaction when
    /// this install came from a referral; installs without one send nothing.
    /// A pending or in-flight referral confirmation reports purchases itself when it finishes, so this
    /// never decides "no attribution" (a purchase right at launch must not cost a cold-start link).
    public func purchaseCompleted() {
        reportIfReferred()
    }

    private func reportIfReferred() {
        guard preferences.string(forKey: "codefluence.confirmedLeadId") != nil else { return }
        reportPurchases()
    }

    /// Test-only injection of the A3 retry dependencies. Not part of the host API.
    func injectRetryDependencies(policy: CodefluenceBackoffPolicy? = nil,
                                 jitter: (() -> Double)? = nil,
                                 scheduler: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
                                 monitor: CodefluenceNetworkMonitor? = nil) {
        stateLock.lock()
        if let policy { backoffPolicy = policy }
        if let jitter { jitterProvider = jitter }
        if let scheduler { self.scheduler = scheduler }
        if let monitor { networkMonitor = monitor; monitorStarted = false }
        stateLock.unlock()
    }

    private func startNetworkMonitorIfNeeded() {
        stateLock.lock()
        guard !monitorStarted, let monitor = networkMonitor else { stateLock.unlock(); return }
        monitorStarted = true
        stateLock.unlock()
        monitor.start(onSatisfied: { [weak self] in
            self?.resumePendingConfirmationIfNeeded()
        })
    }

    /// Automatic catch-up/send of an accepted, unfinished confirmation. No-op
    /// unless an accepted pending request exists. Respects the gate and the
    /// max-attempts cap; schedules a backoff retry on transient failure.
    func resumePendingConfirmationIfNeeded() {
        stateLock.lock()
        let hasPending = preferences.bool(forKey: "codefluence.accepted")
            && preferences.string(forKey: "codefluence.confirmedLeadId") == nil
            && (preferences.string(forKey: "codefluence.pendingToken")?.isEmpty == false)
            && (preferences.string(forKey: "codefluence.pendingAppUserId")?.isEmpty == false)
        let completedAttempts = preferences.integer(forKey: "codefluence.pendingAttempts")
        let allowed = backoffPolicy.canAttempt(afterCompleted: completedAttempts)
        guard hasPending, allowed,
              let token = preferences.string(forKey: "codefluence.pendingToken"),
              let appUserId = preferences.string(forKey: "codefluence.pendingAppUserId") else {
            stateLock.unlock(); return
        }
        stateLock.unlock()
        sendConfirmation(clickToken: token, appUserId: appUserId, isAutomatic: true, completion: nil)
    }

    /// Returns this install's stable UUID; pass it as appAccountToken when starting the purchase.
    public func purchaseAccountToken() -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        if let value = preferences.string(forKey: "codefluence.purchaseAccountToken"), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        preferences.set(value, forKey: "codefluence.purchaseAccountToken")
        return value
    }

    private func urlToken(_ url: URL) -> String? {
        guard let host = apiHost?.host?.lowercased(), url.scheme?.lowercased() == "https", url.host?.lowercased() == host, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/"); guard parts.count == 2, parts[0] == "t" else { return nil }
        let token = String(parts[1])
        guard token.range(of: #"^[^./?#]+\.[^./?#]+\.[0-9]+\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return token
    }
    private func validReferralURL(_ value: String) -> String? { guard let url = URL(string: value) else { return nil }; return urlToken(url) }

    #if canImport(UIKit)
    @MainActor
    public func restoreReferralToken() -> String? {
        if let saved = preferences.string(forKey: "codefluence.clickToken"), !saved.isEmpty { return saved }
        return nil
    }

    /// Asynchronously inspects the pasteboard before reading it. iOS requires
    /// the detection API for privacy-safe pasteboard access.
    @MainActor
    public func restoreReferralTokenAsync() async -> String? {
        if preferences.bool(forKey: "codefluence.noTokenAtLaunch") { return preferences.string(forKey: "codefluence.laterLinkToken") }
        if let saved = preferences.string(forKey: "codefluence.clickToken"), !saved.isEmpty { return saved }
        guard (try? await pasteboard.containsProbableWebURL()) == true else { return nil }
        guard let pasted = pasteboard.string, let token = validReferralURL(pasted) else { return nil }
        preferences.set(token, forKey: "codefluence.clickToken")
        return token
    }

    /// Handles a universal/custom URL and persists only a token addressed to
    /// this configured Codefluence origin.
    @MainActor
    @discardableResult
    public func handleOpenURL(_ url: URL) -> String? {
        let token = urlToken(url) ?? ((url.host == "referral" || url.host == "") ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cf_click_token" || $0.name == "codefluence_click_token" })?.value : nil)
        guard let token, !token.isEmpty else { return nil }
        preferences.set(token, forKey: "codefluence.clickToken")
        return token
    }


    #if canImport(StoreKit)
    /// Reports a verified StoreKit 2 transaction. Pass the
    /// `VerificationResult<Transaction>` you receive from `Transaction.updates`,
    /// `Transaction.currentEntitlements` or `Product.purchase`; the SDK sends
    /// only its signed JWS and the server is the source of truth for price and
    /// state. The `VerificationResult` is the JWS carrier across StoreKit SDK
    /// versions (a decoded `Transaction` no longer exposes `jwsRepresentation`).
    public func reportPurchase(transaction result: VerificationResult<StoreKit.Transaction>, completion: ((Result<Void, Error>) -> Void)? = nil) {
        reportPurchaseJWS(result.jwsRepresentation, completion: completion)
    }
    #endif

    private func reportPurchaseJWS(_ jws: String, completion: ((Result<Void, Error>) -> Void)?) {
        stateLock.lock(); let host = apiHost; let key = publicKey; stateLock.unlock()
        guard let host, key.hasPrefix("pk_"), let url = URL(string: host.absoluteString + "/track/purchase") else { completion?(.failure(failure(11, "SDK is not configured"))); return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try? JSONSerialization.data(withJSONObject: ["signedTransaction": jws])
        session.dataTask(with: request) { [weak self] _, response, error in guard let self else { return }; let result: Result<Void, Error> = error.map { .failure($0) } ?? (((response as? HTTPURLResponse)?.statusCode ?? 500) < 300 ? .success(()) : .failure(self.failure(1, "Purchase report failed"))); self.deliverVoid(result, completion) }.resume()
    }
    private func deliverVoid(_ result: Result<Void, Error>, _ completion: ((Result<Void, Error>) -> Void)?) { guard let completion else { return }; DispatchQueue.main.async { completion(result) } }

    public protocol AttestationProvider { func attest(completion: @escaping (String?) -> Void) }
    /// Sends at most one aggregate heartbeat per local day. The provider is an
    /// injectable App Attest implementation; no device identifier is sent.
    public func heartbeat(appVersion: String? = nil, sdkVersion: String = Codefluence.version, attestation: AttestationProvider? = nil, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let key = "codefluence.heartbeat.\(day)"
        stateLock.lock(); if preferences.bool(forKey: key) { stateLock.unlock(); completion?(.success(())); return }; stateLock.unlock()
        stateLock.lock(); let host = apiHost; let keyValue = publicKey; stateLock.unlock()
        guard let host, keyValue.hasPrefix("pk_") else { completion?(.failure(failure(11, "SDK is not configured"))); return }
        let send: (String?) -> Void = { [weak self] assertion in
            guard let self else { return }
            self.postHeartbeat(host: host, key: keyValue, appVersion: appVersion, sdkVersion: sdkVersion, attestation: assertion) { result in
                switch result {
                case .failure(let error): completion?(.failure(error))
                case .success(let status):
                    guard (200..<300).contains(status) else { completion?(.failure(self.failure(1, "Heartbeat failed"))); return }
                    self.preferences.set(true, forKey: key); completion?(.success(()))
                }
            }
        }
        if let attestation { attestation.attest(completion: send) } else { send(nil) }
    }

    @MainActor
    public func showConfirmationIfNeeded(from presenter: UIViewController, appUserId: String, clickToken: String? = nil, completion: @escaping (Result<String?, Error>) -> Void) {
        guard !preferences.bool(forKey: "codefluence.decisionMade") else { return }
        guard gate.beginPrompt() else {
            completion(.failure(failure(8, "Referral confirmation is already being presented")))
            return
        }
        let token: String
        switch prepareConfirmation(for: clickToken ?? restoreReferralToken()) {
        case .present(let restored): token = restored
        case .noAttribution:
            gate.endPrompt()
            completion(.success(nil))
            return
        case .skip:
            gate.endPrompt()
            return
        }
        guard !appUserId.isEmpty, presenter.isViewLoaded, presenter.view.window != nil,
              presenter.presentedViewController == nil else {
            gate.endPrompt()
            completion(.failure(failure(9, "A visible presenter and stable customer ID are required")))
            return
        }
        let copy = ConfirmationCopy(languageIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        let alert = UIAlertController(title: copy.title, message: copy.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: copy.no, style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.gate.endPrompt()
            self.stateLock.lock()
            guard !self.preferences.bool(forKey: "codefluence.decisionMade") else {
                self.stateLock.unlock()
                completion(.failure(self.failure(10, "Referral confirmation already has a decision")))
                return
            }
            self.preferences.set(true, forKey: "codefluence.decisionMade")
            self.preferences.set(false, forKey: "codefluence.accepted")
            self.preferences.removeObject(forKey: "codefluence.pendingToken")
            self.preferences.removeObject(forKey: "codefluence.pendingAppUserId")
            self.stateLock.unlock()
            completion(.success(nil))
        })
        alert.addAction(UIAlertAction(title: copy.yes, style: .default) { [weak self] _ in
            self?.gate.endPrompt()
            self?.confirm(clickToken: token, appUserId: appUserId) { result in
                if case .failure(let error) = result, error is ExistingUsersNotIncluded { completion(.success(nil)) }
                    else { completion(result.map { Optional($0) }) }
            }
        })
        presenter.present(alert, animated: true)
    }
    #endif

    /// Restores a referral token and attributes it without presenting a confirmation sheet.
    ///
    /// Use this for a product policy where following a verified referral link is the
    /// attribution decision. A missing token is a normal unattributed start; it does
    /// not create a network request. An accepted but unfinished request remains
    /// retryable with `retryPendingConfirmation`.
    @MainActor
    public func autoConfirmIfAvailable(appUserId: String, clickToken: String? = nil, completion: @escaping (Result<String?, Error>) -> Void) {
        guard !appUserId.isEmpty else {
            deliverOptional(.failure(failure(9, "A stable customer ID is required")), completion)
            return
        }
        guard !preferences.bool(forKey: "codefluence.decisionMade") else {
            let leadId = preferences.string(forKey: "codefluence.confirmedLeadId")
            let savedCustomer = preferences.string(forKey: "codefluence.confirmedAppUserId")
            deliverOptional(savedCustomer == nil || savedCustomer == appUserId ? .success(leadId) : .failure(failure(4, "Referral attribution belongs to a different customer")), completion)
            return
        }
        guard gate.beginPrompt() else {
            deliverOptional(.failure(failure(8, "Referral attribution is already being resolved")), completion)
            return
        }
        let finish: (String?) -> Void = { [self] restoredToken in
            switch prepareConfirmation(for: restoredToken) {
            case .present(let token):
                gate.endPrompt()
                confirm(clickToken: token, appUserId: appUserId) { result in
                    if case .failure(let error) = result, error is ExistingUsersNotIncluded { completion(.success(nil)) }
                    else { completion(result.map { Optional($0) }) }
                }
            case .noAttribution:
                gate.endPrompt()
                deliverOptional(.success(nil), completion)
            case .skip:
                gate.endPrompt()
                let leadId = preferences.string(forKey: "codefluence.confirmedLeadId")
                let savedCustomer = preferences.string(forKey: "codefluence.confirmedAppUserId")
                deliverOptional(savedCustomer == nil || savedCustomer == appUserId ? .success(leadId) : .failure(failure(4, "Referral attribution belongs to a different customer")), completion)
            }
        }
        if preferences.bool(forKey: "codefluence.noTokenAtLaunch") {
            finish(preferences.string(forKey: "codefluence.laterLinkToken"))
            return
        }
        #if canImport(UIKit)
        if let clickToken { finish(clickToken); return }
        // 저장된 토큰(딥링크로 받은 것)이 먼저, 없으면 랜딩이 복사한 클립보드를 복원한다.
        // 클립보드는 `restoreReferralTokenAsync`가 패턴 검사 뒤에만, 서명 형식이 맞을 때만 읽는다.
        if let saved = restoreReferralToken() { finish(saved); return }
        Task { @MainActor in finish(await self.restoreReferralTokenAsync()) }
        #else
        finish(clickToken ?? preferences.string(forKey: "codefluence.clickToken"))
        #endif
    }

    // Restoration may finish after another call accepts a referral. Check and
    // persist under the same lock as confirm; never erase an accepted identity.
    func prepareConfirmation(for token: String?) -> ConfirmationPreparation {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !preferences.bool(forKey: "codefluence.decisionMade"),
              !preferences.bool(forKey: "codefluence.accepted"),
              preferences.object(forKey: "codefluence.pendingToken") == nil,
              preferences.object(forKey: "codefluence.pendingAppUserId") == nil,
              preferences.object(forKey: "codefluence.confirmedLeadId") == nil else { return .skip }
        if preferences.bool(forKey: "codefluence.noTokenAtLaunch") && (token == nil || token != preferences.string(forKey: "codefluence.laterLinkToken")) { return .noAttribution }
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .present(token) }
        preferences.set(true, forKey: "codefluence.noTokenAtLaunch")
        return .noAttribution
    }

    /// Call only after the host's explicit Yes decision. A saved No cannot be bypassed.
    public func confirm(clickToken: String, appUserId: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard !clickToken.isEmpty, !appUserId.isEmpty else {
            deliver(.failure(failure(2, "A referral token and stable customer ID are required")), completion)
            return
        }
        stateLock.lock()
        if preferences.bool(forKey: "codefluence.decisionMade") && !preferences.bool(forKey: "codefluence.accepted") {
            stateLock.unlock()
            deliver(.failure(failure(3, "Referral confirmation was declined")), completion)
            return
        }
        if let leadId = preferences.string(forKey: "codefluence.confirmedLeadId"), !leadId.isEmpty {
            let sameCustomer = preferences.string(forKey: "codefluence.confirmedAppUserId") == appUserId
            stateLock.unlock()
            deliver(sameCustomer ? .success(leadId) : .failure(failure(4, "Referral confirmation is already complete")), completion)
            return
        }
        if let pendingToken = preferences.string(forKey: "codefluence.pendingToken"),
           let pendingCustomer = preferences.string(forKey: "codefluence.pendingAppUserId"),
           pendingToken != clickToken || pendingCustomer != appUserId {
            stateLock.unlock()
            deliver(.failure(failure(5, "Retry must preserve the accepted token and customer ID")), completion)
            return
        }
        if preferences.bool(forKey: "codefluence.noTokenAtLaunch"), preferences.string(forKey: "codefluence.pendingToken") == nil, clickToken != preferences.string(forKey: "codefluence.laterLinkToken") {
            stateLock.unlock()
            deliver(.failure(failure(3, "A later referral must arrive through a link")), completion)
            return
        }
        if preferences.string(forKey: "codefluence.pendingLaunchKind") == nil {
            preferences.set(preferences.bool(forKey: "codefluence.noTokenAtLaunch") ? "later" : "first_launch", forKey: "codefluence.pendingLaunchKind")
        }
        preferences.set(true, forKey: "codefluence.decisionMade")
        preferences.set(true, forKey: "codefluence.accepted")
        preferences.set(clickToken, forKey: "codefluence.clickToken")
        preferences.set(clickToken, forKey: "codefluence.pendingToken")
        preferences.set(appUserId, forKey: "codefluence.pendingAppUserId")
        // A3: one idempotency key per queued confirmation, reused across retries.
        if (preferences.string(forKey: "codefluence.pendingIdempotencyKey") ?? "").isEmpty {
            preferences.set(UUID().uuidString, forKey: "codefluence.pendingIdempotencyKey")
            preferences.set(0, forKey: "codefluence.pendingAttempts")
        }
        stateLock.unlock()
        sendConfirmation(clickToken: clickToken, appUserId: appUserId, completion: completion)
    }

    /// Retries only an accepted, unfinished confirmation, without showing a dialog.
    /// Resets the automatic backoff state so the manual attempt is immediate.
    public func retryPendingConfirmation(completion: @escaping (Result<String, Error>) -> Void) {
        stateLock.lock()
        guard preferences.bool(forKey: "codefluence.accepted"),
              preferences.string(forKey: "codefluence.confirmedLeadId") == nil,
              let token = preferences.string(forKey: "codefluence.pendingToken"), !token.isEmpty,
              let appUserId = preferences.string(forKey: "codefluence.pendingAppUserId"), !appUserId.isEmpty else {
            stateLock.unlock()
            deliver(.failure(failure(6, "No accepted pending confirmation is available")), completion)
            return
        }
        // Manual retry resets backoff attempts and cancels a scheduled auto retry.
        preferences.set(0, forKey: "codefluence.pendingAttempts")
        retryScheduled = false
        stateLock.unlock()
        sendConfirmation(clickToken: token, appUserId: appUserId, completion: completion)
    }

    private func sendConfirmation(clickToken: String, appUserId: String, isAutomatic: Bool = false, completion: ((Result<String, Error>) -> Void)?) {
        guard gate.beginRequest() else {
            // Automatic resend never races a manual/in-flight request; stay silent.
            if !isAutomatic { deliverMaybe(.failure(failure(7, "Referral confirmation is already in progress")), completion) }
            return
        }
        stateLock.lock()
        let host = apiHost
        let key = publicKey
        let idempotencyKey = preferences.string(forKey: "codefluence.pendingIdempotencyKey")
        preferences.set(preferences.integer(forKey: "codefluence.pendingAttempts") + 1, forKey: "codefluence.pendingAttempts")
        retryScheduled = false
        stateLock.unlock()
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let host,
              let scheme = host.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              host.host != nil,
              host.user == nil,
              host.query == nil,
              host.fragment == nil,
              host.path.isEmpty || host.path == "/",
              normalizedKey.count > 3,
              normalizedKey.hasPrefix("pk_") else {
            gate.endRequest()
            // Not configured is not a server rejection; keep the queue so a later
            // configure can retry, and surface the structured error to the caller.
            deliverMaybe(.failure(failure(11, "Call configure with an explicit API host and pk_ public key before confirming a referral")), completion)
            return
        }

        var request = URLRequest(url: host.appendingPathComponent("track/confirm"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey, !idempotencyKey.isEmpty {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        var payload: [String: Any] = ["clickToken": clickToken, "appUserId": appUserId]
        payload["launchKind"] = preferences.string(forKey: "codefluence.pendingLaunchKind") ?? "first_launch"
        payload["purchaseAccountToken"] = purchaseAccountToken()
        stateLock.lock(); let source = transactionSource; stateLock.unlock()
        let baseRequest = request
        let basePayload = payload
        Task { [weak self] in
        guard let self else { return }
        var request = baseRequest
        var payload = basePayload
        // Apple-signed AppTransaction lets the server link later purchases by appTransactionId.
        // Retries reuse the idempotency key, so the first attempt's AppTransaction (or its absence) is kept with the queue.
        let pinned: String? = { self.stateLock.lock(); defer { self.stateLock.unlock() }; return self.preferences.string(forKey: "codefluence.pendingAppTransactionJws") }()
        let appJWS: String?
        if let pinned { appJWS = pinned.isEmpty ? nil : pinned } else {
            appJWS = await Self.firstOrNil(timeout: self.appTransactionTimeout, { await source.appTransactionJWS() })
            self.stateLock.lock(); self.preferences.set(appJWS ?? "", forKey: "codefluence.pendingAppTransactionJws"); self.stateLock.unlock()
        }
        if let appJWS { payload["appTransactionJws"] = appJWS }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        self.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            var retryClass: ConfirmationFailureClass?
            let result: Result<String, Error>
            if error != nil {
                result = .failure(self.failure(1, "Referral confirmation request failed"))
                retryClass = .retryable
            } else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data,
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let leadId = object["leadId"] as? String, !leadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.persistConfirmed(leadId: leadId, appUserId: appUserId, responsePurchaseAccountToken: object["purchaseAccountToken"] as? String)
                self.gate.endRequest()
                self.deliverMaybe(.success(leadId), completion)
                self.reportPurchases()
                return
            } else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data,
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["leadId"] is NSNull,
                      object["reason"] as? String == "existing_users_not_included" {
                self.clearPendingQueue()
                self.stateLock.lock()
                self.preferences.set(true, forKey: "codefluence.noTokenAtLaunch")
                self.preferences.removeObject(forKey: "codefluence.decisionMade")
                self.preferences.removeObject(forKey: "codefluence.accepted")
                self.preferences.removeObject(forKey: "codefluence.laterLinkToken")
                self.preferences.removeObject(forKey: "codefluence.clickToken")
                self.stateLock.unlock()
                self.gate.endRequest()
                self.deliverMaybe(.failure(ExistingUsersNotIncluded()), completion)
                return
            } else if let http = response as? HTTPURLResponse {
                let classification = ConfirmationFailureClass.forStatus(http.statusCode)
                retryClass = classification
                result = http.statusCode == 409 ? .failure(self.failure(14, "confirmation rejected")) : .failure(self.failure(1, "Referral confirmation was rejected by the server (HTTP \(http.statusCode))"))
            } else {
                // No HTTPURLResponse and no error: treat as transient.
                result = .failure(self.failure(1, "Referral confirmation response is invalid"))
                retryClass = .retryable
            }
            self.gate.endRequest()
            if retryClass == .permanent {
                // Server rejected this request permanently; stop retrying.
                self.clearPendingQueue()
            } else {
                // Transient failure: keep the queue and schedule the next attempt.
                self.scheduleAutomaticRetry()
            }
            self.deliverMaybe(result, completion)
        }.resume()
        }
    }

    /// Reports every App Store transaction this install hasn't reported yet. Call it after a
    /// purchase succeeds (including purchases made through RevenueCat or other purchase SDKs);
    /// it also runs on launch and right after a referral is confirmed. Completion gets the number
    /// of transactions the server accepted (including ones it already had).
    public func reportPurchases(completion: ((Result<Int, Error>) -> Void)? = nil) {
        stateLock.lock(); let host = apiHost; let key = publicKey; let source = transactionSource; stateLock.unlock()
        guard let host, key.hasPrefix("pk_"), let url = URL(string: host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/track/purchase") else {
            deliverCount(.failure(failure(11, "SDK is not configured")), completion); return
        }
        stateLock.lock()
        if reportInFlight { stateLock.unlock(); deliverCount(.success(0), completion); return }
        reportInFlight = true
        stateLock.unlock()
        Task { [weak self] in
            guard let self else { return }
            defer { self.stateLock.lock(); self.reportInFlight = false; self.stateLock.unlock() }
            let reported = Set(self.preferences.stringArray(forKey: "codefluence.reportedTransactionIds") ?? [])
            let pending = await source.signedTransactions().filter { !reported.contains($0.transactionId) }
            var accepted: [String] = []
            for transaction in pending {
                var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["signedTransaction": transaction.jws])
                if let (_, response) = try? await self.session.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                    accepted.append(transaction.transactionId)
                }
            }
            if !accepted.isEmpty {
                self.stateLock.lock()
                let merged = (self.preferences.stringArray(forKey: "codefluence.reportedTransactionIds") ?? []) + accepted
                self.preferences.set(Array(merged.suffix(200)), forKey: "codefluence.reportedTransactionIds")
                self.stateLock.unlock()
            }
            self.deliverCount(.success(accepted.count), completion)
        }
    }
    private func deliverCount(_ result: Result<Int, Error>, _ completion: ((Result<Int, Error>) -> Void)?) { guard let completion else { return }; DispatchQueue.main.async { completion(result) } }

    /// Returns the operation's value, or nil if it doesn't finish within `timeout`.
    /// The operation keeps running in the background; it is never awaited past the deadline.
    static func firstOrNil(timeout: TimeInterval, _ operation: @escaping () async -> String?) async -> String? {
        final class Once: @unchecked Sendable { private let lock = NSLock(); private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            Task { let value = await operation(); if once.claim() { continuation.resume(returning: value) } }
            Task { try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)); if once.claim() { continuation.resume(returning: nil) } }
        }
    }

    private func persistConfirmed(leadId: String, appUserId: String, responsePurchaseAccountToken: String?) {
        stateLock.lock()
        preferences.set(leadId, forKey: "codefluence.confirmedLeadId")
        preferences.set(appUserId, forKey: "codefluence.confirmedAppUserId")
        if let token = responsePurchaseAccountToken, !token.isEmpty {
            preferences.set(token, forKey: "codefluence.confirmedPurchaseAccountToken")
        }
        preferences.removeObject(forKey: "codefluence.pendingToken")
        preferences.removeObject(forKey: "codefluence.pendingAppUserId")
        preferences.removeObject(forKey: "codefluence.pendingIdempotencyKey")
        preferences.removeObject(forKey: "codefluence.pendingAppTransactionJws")
        preferences.removeObject(forKey: "codefluence.pendingLaunchKind")
        preferences.removeObject(forKey: "codefluence.pendingAttempts")
        retryScheduled = false
        stateLock.unlock()
    }

    private func clearPendingQueue() {
        stateLock.lock()
        preferences.removeObject(forKey: "codefluence.pendingToken")
        preferences.removeObject(forKey: "codefluence.pendingAppUserId")
        preferences.removeObject(forKey: "codefluence.pendingIdempotencyKey")
        preferences.removeObject(forKey: "codefluence.pendingAppTransactionJws")
        preferences.removeObject(forKey: "codefluence.pendingLaunchKind")
        preferences.removeObject(forKey: "codefluence.pendingAttempts")
        retryScheduled = false
        stateLock.unlock()
    }

    private func scheduleAutomaticRetry() {
        stateLock.lock()
        let completedAttempts = preferences.integer(forKey: "codefluence.pendingAttempts")
        guard !retryScheduled,
              preferences.bool(forKey: "codefluence.accepted"),
              preferences.string(forKey: "codefluence.confirmedLeadId") == nil,
              let token = preferences.string(forKey: "codefluence.pendingToken"), !token.isEmpty,
              let appUserId = preferences.string(forKey: "codefluence.pendingAppUserId"), !appUserId.isEmpty,
              backoffPolicy.canAttempt(afterCompleted: completedAttempts) else {
            stateLock.unlock(); return
        }
        // Next attempt number is completedAttempts + 1 (1-based).
        let delay = backoffPolicy.delay(forAttempt: completedAttempts + 1, jitter: jitterProvider())
        retryScheduled = true
        let scheduler = self.scheduler
        stateLock.unlock()
        scheduler(delay) { [weak self] in
            self?.sendConfirmation(clickToken: token, appUserId: appUserId, isAutomatic: true, completion: nil)
        }
    }

    private func deliverMaybe(_ result: Result<String, Error>, _ completion: ((Result<String, Error>) -> Void)?) {
        guard let completion else { return }
        DispatchQueue.main.async { completion(result) }
    }

    /// Reads the server's normalized subscription status for the confirmed
    /// referral (C3). **Read-only view, not an entitlement decision** — do not
    /// gate paid features on it; use your payment provider for access control.
    ///
    /// Uses the `leadId` and `purchaseAccountToken` saved from `/track/confirm`.
    /// Fails with `CodefluenceError.noSubscriptionReference` when no confirmed
    /// referral is stored, and `.subscriptionNotFound` on a 404.
    public func subscriptionStatus(completion: @escaping (Result<CodefluenceSubscriptionStatus, Error>) -> Void) {
        stateLock.lock()
        let host = apiHost
        let key = publicKey
        let leadId = preferences.string(forKey: "codefluence.confirmedLeadId")
        let purchaseAccountToken = preferences.string(forKey: "codefluence.confirmedPurchaseAccountToken")
            ?? preferences.string(forKey: "codefluence.purchaseAccountToken")
        stateLock.unlock()
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let host,
              let scheme = host.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              host.host != nil, host.user == nil, host.query == nil, host.fragment == nil,
              host.path.isEmpty || host.path == "/",
              normalizedKey.count > 3, normalizedKey.hasPrefix("pk_") else {
            deliverSubscription(.failure(failure(11, "Call configure with an explicit API host and pk_ public key before reading subscription status")), completion)
            return
        }
        guard let leadId, !leadId.isEmpty, let purchaseAccountToken, !purchaseAccountToken.isEmpty else {
            deliverSubscription(.failure(failure(12, "No confirmed referral is available to read subscription status")), completion)
            return
        }

        var request = URLRequest(url: host.appendingPathComponent("track/subscription"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["leadId": leadId, "purchaseAccountToken": purchaseAccountToken], options: [.sortedKeys])
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if error != nil {
                self.deliverSubscription(.failure(self.failure(1, "Subscription status request failed")), completion)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                self.deliverSubscription(.failure(self.failure(13, "No subscription record was found for this customer")), completion)
                return
            }
            guard (200..<300).contains(status), let data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let parsed = Self.parseSubscription(object) else {
                self.deliverSubscription(.failure(self.failure(1, "Subscription status response is invalid")), completion)
                return
            }
            self.deliverSubscription(.success(parsed), completion)
        }.resume()
    }

    static func parseSubscription(_ object: [String: Any]) -> CodefluenceSubscriptionStatus? {
        guard let stateRaw = object["state"] as? String,
              let state = CodefluenceSubscriptionStatus.State(rawValue: stateRaw) else { return nil }
        let sandbox = object["sandbox"] as? Bool ?? false
        let updatedAt = object["updatedAt"] as? String
        var events: [CodefluenceSubscriptionStatus.Event] = []
        if let rawEvents = object["events"] as? [[String: Any]] {
            for entry in rawEvents {
                guard let type = entry["type"] as? String,
                      let occurredAt = entry["occurredAt"] as? String,
                      let source = entry["source"] as? String else { continue }
                events.append(CodefluenceSubscriptionStatus.Event(
                    kind: CodefluenceSubscriptionStatus.Event.Kind(rawValue: type),
                    rawType: type, occurredAt: occurredAt, source: source))
            }
        }
        return CodefluenceSubscriptionStatus(state: state, sandbox: sandbox, updatedAt: updatedAt, events: events)
    }

    private func deliverSubscription(_ result: Result<CodefluenceSubscriptionStatus, Error>, _ completion: @escaping (Result<CodefluenceSubscriptionStatus, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    private func failure(_ code: Int, _ message: String) -> Error {
        switch code {
        case 1: return CodefluenceError.requestFailed(message: message)
        case 2: return CodefluenceError.missingReferralInput
        case 3: return CodefluenceError.declined
        case 4: return CodefluenceError.attributionForDifferentCustomer
        case 5: return CodefluenceError.retryIdentityMismatch
        case 6: return CodefluenceError.noPendingConfirmation
        case 7: return CodefluenceError.requestInProgress
        case 8: return CodefluenceError.alreadyPresenting
        case 9: return CodefluenceError.presenterOrCustomerRequired
        case 10: return CodefluenceError.decisionAlreadyMade
        case 11: return CodefluenceError.notConfigured(message: message)
        case 12: return CodefluenceError.noSubscriptionReference
        case 13: return CodefluenceError.subscriptionNotFound
        case 14: return CodefluenceError.confirmationRejected
        default: return NSError(domain: "Codefluence", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func deliver(_ result: Result<String, Error>, _ completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    private func deliverOptional(_ result: Result<String?, Error>, _ completion: @escaping (Result<String?, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }
}

enum ConfirmationPreparation: Equatable {
    case present(String), noAttribution, skip
}

struct ConfirmationCopy {
    let title: String
    let message: String
    let yes: String
    let no: String

    init(languageIdentifier: String) {
        let locale = Locale(identifier: languageIdentifier)
        let korean: Bool
        if #available(iOS 16, macOS 13, *) {
            korean = locale.language.languageCode?.identifier == "ko"
        } else {
            korean = locale.languageCode == "ko"
        }
        title = korean ? "이 소개로 시작할까요?" : "Start with this referral?"
        message = korean ? "이 소개 링크를 결제 귀속에 사용합니다." : "Use this referral link to attribute your purchases."
        yes = korean ? "예" : "Yes"
        no = korean ? "아니오" : "No"
    }
}

/** One presentation/request admission at a time, independently of callback queues. */
final class ConfirmationGate {
    private let lock = NSLock()
    private var presenting = false
    private var requesting = false

    func beginPrompt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !presenting else { return false }
        presenting = true
        return true
    }
    func endPrompt() { lock.lock(); presenting = false; lock.unlock() }
    func beginRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !requesting else { return false }
        requesting = true
        return true
    }
    func endRequest() { lock.lock(); requesting = false; lock.unlock() }
}

private struct ExistingUsersNotIncluded: Error {}
