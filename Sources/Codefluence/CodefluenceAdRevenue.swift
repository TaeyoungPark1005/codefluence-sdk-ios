import Foundation

/// AdMob impression-level precision, mirrored from `GADAdValuePrecision` so the SDK does not link the Google Mobile Ads SDK.
/// Documentation: https://developers.google.com/admob/ios/impression-level-ad-revenue
public enum CodefluenceAdValuePrecision: Equatable {
    case unknown
    case estimated
    case publisherProvided
    case precise
}

/// Result of one `flushAdRevenueIfNeeded` call. Never an error: a failed report must not affect the host app.
public enum CodefluenceAdRevenueOutcome: Equatable {
    /// The server accepted the batch. `attested` is true when it counts towards the referral share (App Attest proof verified).
    case sent(attested: Bool)
    /// Nothing was sent. `reason` is a short machine-readable code.
    case skipped(reason: String)
}

/// Ad revenue reports (SPEC §26.2). The host app forwards AdMob paid events; the SDK adds them up on the device and sends one
/// batch at most once an hour. Everything is gated by the server: until `GET /track/signal-config` answers `adRevenue: true`
/// nothing leaves the device. No advertising identifier and no ATT prompt are involved, only amounts, currency and counts.
extension Codefluence {
    enum AdRevenueKey {
        static let pending = "codefluence.adrev.pending"
        static let lastFlushAt = "codefluence.adrev.lastFlushAt"
        static let stoppedLeadId = "codefluence.adrev.stoppedLeadId"
        static let backoffUntil = "codefluence.adrev.backoffUntil"
    }

    /// Minimum time between two batches. The server accepts 24 batches per referred install per day.
    static let adRevenueFlushInterval: TimeInterval = 3600
    /// Upper bound for one batch, matching the server limit (1,000 currency units, 100,000 impressions).
    static let maxBatchMicros: Int64 = 1_000_000_000
    static let maxBatchImpressions = 100_000
    static let adRevenueCurrencies: Set<String> = ["KRW", "USD", "JPY", "EUR"]

    /// Forwards one AdMob paid event. Call it from the paid event handler of every ad format
    /// (`ad.paidEventHandler = { adValue in Codefluence.shared.reportAdRevenue(value: adValue.value as Decimal, currencyCode: adValue.currencyCode, precision: .precise) }`).
    /// `precision: .unknown` (for example test ads) only counts the impression and adds no revenue.
    public func reportAdRevenue(value: Decimal, currencyCode: String, precision: CodefluenceAdValuePrecision) {
        var micros = value * 1_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &micros, 0, .plain)
        let asDouble = NSDecimalNumber(decimal: rounded).doubleValue
        guard asDouble.isFinite, asDouble >= 0, asDouble <= Double(Self.maxBatchMicros) else { return }
        reportAdRevenue(valueMicros: Int64(asDouble), currencyCode: currencyCode, precision: precision)
    }

    /// Same as `reportAdRevenue(value:currencyCode:precision:)` for callers that already hold micros (Android style `AdValue`).
    public func reportAdRevenue(valueMicros: Int64, currencyCode: String, precision: CodefluenceAdValuePrecision) {
        let currency = currencyCode.uppercased()
        guard valueMicros >= 0, Self.adRevenueCurrencies.contains(currency) else { return }
        let counted = precision == .unknown ? 0 : valueMicros
        stateLock.lock()
        var pending = Self.readPending(preferences)
        var entry = pending[currency] ?? [0, 0, 0]
        entry[0] = min(entry[0] + Int(counted), Int(Self.maxBatchMicros))
        if precision == .unknown { entry[2] = min(entry[2] + 1, Self.maxBatchImpressions) } else { entry[1] = min(entry[1] + 1, Self.maxBatchImpressions) }
        pending[currency] = entry
        preferences.set(pending, forKey: AdRevenueKey.pending)
        stateLock.unlock()
        flushAdRevenueIfNeeded()
    }

    /// Sends the accumulated batch if the server has the feature on and the hourly gate allows it.
    /// Safe to call on every launch and foreground. Failures are returned as `.skipped` and never thrown.
    public func flushAdRevenueIfNeeded(completion: ((CodefluenceAdRevenueOutcome) -> Void)? = nil) {
        Task.detached { [weak self] in
            guard let self else { return }
            let outcome = await self.performAdRevenueFlush(now: self.signalClock())
            if let completion { DispatchQueue.main.async { completion(outcome) } }
        }
    }

    private static func readPending(_ preferences: UserDefaults) -> [String: [Int]] {
        (preferences.dictionary(forKey: AdRevenueKey.pending) as? [String: [Int]]) ?? [:]
    }

    /// Re-adds a batch that could not be sent so no revenue is lost.
    private func restorePending(_ batch: (currency: String, entry: [Int])) {
        stateLock.lock()
        var pending = Self.readPending(preferences)
        var entry = pending[batch.currency] ?? [0, 0, 0]
        for index in 0..<3 { entry[index] += batch.entry[index] }
        entry[0] = min(entry[0], Int(Self.maxBatchMicros)); entry[1] = min(entry[1], Self.maxBatchImpressions); entry[2] = min(entry[2], Self.maxBatchImpressions)
        pending[batch.currency] = entry
        preferences.set(pending, forKey: AdRevenueKey.pending)
        stateLock.unlock()
    }

    func performAdRevenueFlush(now: Date) async -> CodefluenceAdRevenueOutcome {
        stateLock.lock()
        let pending = Self.readPending(preferences)
        let lastFlush = preferences.double(forKey: AdRevenueKey.lastFlushAt)
        let backoff = preferences.double(forKey: AdRevenueKey.backoffUntil)
        stateLock.unlock()
        guard !pending.isEmpty else { return .skipped(reason: "nothing_pending") }
        let nowSeconds = now.timeIntervalSince1970
        if nowSeconds < backoff { return .skipped(reason: "backoff") }
        if lastFlush > 0, lastFlush <= nowSeconds, nowSeconds - lastFlush < Self.adRevenueFlushInterval { return .skipped(reason: "interval") }
        guard let config = configIdentity() else { return .skipped(reason: "not_configured") }
        // Only the public key leaves the device for this check (no install, lead or device identifier).
        _ = await serverEnabled(config, now: now)
        stateLock.lock(); let adRevenueOn = preferences.object(forKey: SignalKey.adRevenueEnabled) as? Bool ?? false; let signalsOn = preferences.object(forKey: SignalKey.enabled) as? Bool ?? false; stateLock.unlock()
        guard adRevenueOn else { return .skipped(reason: "disabled") }

        // Take one currency at a time; the rest goes in the next batch.
        guard let currency = pending.keys.sorted().first, let entry = pending[currency] else { return .skipped(reason: "nothing_pending") }
        stateLock.lock()
        var remaining = Self.readPending(preferences); remaining.removeValue(forKey: currency)
        if remaining.isEmpty { preferences.removeObject(forKey: AdRevenueKey.pending) } else { preferences.set(remaining, forKey: AdRevenueKey.pending) }
        preferences.set(nowSeconds, forKey: AdRevenueKey.lastFlushAt)
        stateLock.unlock()
        let report: [String: Any] = ["currency": currency, "valueMicros": entry[0], "impressions": entry[1], "unknownImpressions": entry[2]]
        let batch = (currency: currency, entry: entry)

        // A referred install with App Attest sends a proven batch that counts towards the creator share.
        // Everything else (no referral, window closed, no attestation) goes in the unproven total used only as the denominator.
        if signalsOn, appAttest.isSupported, let identity = signalIdentity(), stateString(AdRevenueKey.stoppedLeadId) != identity.leadId {
            do {
                let registration = try await ensureAttestKey(identity)
                if case .ready(let keyId) = registration,
                   let challenge = try await signalChallenge(identity, purpose: "ad_revenue", stop: { [self] leadId in stateLock.lock(); preferences.set(leadId, forKey: AdRevenueKey.stoppedLeadId); stateLock.unlock() }) {
                    let clientData = challenge + "\n" + "\(currency),\(entry[0]),\(entry[1]),\(entry[2])"
                    let assertion = try await appAttest.generateAssertion(keyId, clientDataHash: sha256(clientData))
                    let body: [String: Any] = ["leadId": identity.leadId, "purchaseAccountToken": identity.token, "challenge": challenge, "report": report,
                                               "proof": ["type": "app_attest", "keyId": keyId, "assertion": assertion.base64EncodedString()]]
                    let result = try await signalRequest(identity, path: "track/ad-revenue", body: body)
                    if result.status == 429 { setBackoff(nowSeconds + 3600); restorePending(batch); return .skipped(reason: "rate_limited") }
                    if (200..<300).contains(result.status), (result.json["accepted"] as? Bool) == true {
                        if (result.json["attested"] as? Bool) == true { return .sent(attested: true) }
                        // Proof rejected: the value was not stored, so send it as part of the unproven total below.
                    } else if (200..<300).contains(result.status), (result.json["collect"] as? Bool) == false {
                        // The server no longer wants a referral batch from this install: fall through to the unproven total.
                    } else { restorePending(batch); return .skipped(reason: "rejected") }
                }
            } catch {
                // Attestation failed on the device: the revenue is still part of the app total.
            }
        }
        return await sendUnproven(config, report: report, batch: batch, nowSeconds: nowSeconds)
    }

    private func sendUnproven(_ config: SignalIdentity, report: [String: Any], batch: (currency: String, entry: [Int]), nowSeconds: TimeInterval) async -> CodefluenceAdRevenueOutcome {
        do {
            let result = try await signalRequest(config, path: "track/ad-revenue", body: ["report": report])
            if result.status == 429 { setBackoff(nowSeconds + 3600); restorePending(batch); return .skipped(reason: "rate_limited") }
            // 409: the server switched the feature off or the product is not an ad product. Drop the batch instead of retrying forever.
            if result.status == 409 { return .skipped(reason: "disabled") }
            guard (200..<300).contains(result.status), (result.json["accepted"] as? Bool) == true else { restorePending(batch); return .skipped(reason: "rejected") }
            return .sent(attested: false)
        } catch {
            restorePending(batch)
            return .skipped(reason: "error")
        }
    }

    private func setBackoff(_ until: TimeInterval) {
        stateLock.lock(); preferences.set(until, forKey: AdRevenueKey.backoffUntil); stateLock.unlock()
    }

    /// Host and public key only (empty lead), for the capability check and the unproven total.
    func configIdentity() -> SignalIdentity? {
        stateLock.lock(); defer { stateLock.unlock() }
        let normalized = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = apiHost, let scheme = host.scheme?.lowercased(), scheme == "http" || scheme == "https", host.host != nil, host.user == nil, host.query == nil, host.fragment == nil,
              host.path.isEmpty || host.path == "/", normalized.count > 3, normalized.hasPrefix("pk_") else { return nil }
        return SignalIdentity(host: host, key: normalized, leadId: "", token: "")
    }
}
