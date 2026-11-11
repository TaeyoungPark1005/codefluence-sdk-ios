import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Result of one `sendActivitySignalIfNeeded` call. Never an error: a failed signal must not affect the host app.
public enum CodefluenceActivitySignalOutcome: Equatable {
    /// The server accepted the signal. `attested` is whether the App Attest proof was verified.
    case sent(attested: Bool)
    /// Nothing was sent. `reason` is a short machine-readable code.
    case skipped(reason: String)
}

/// App Attest operations, injectable so package tests can run without a device.
protocol CodefluenceAppAttest {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Used where DeviceCheck does not exist or App Attest is unavailable (simulator, most app extensions).
struct UnsupportedAppAttest: CodefluenceAppAttest {
    var isSupported: Bool { false }
    func generateKey() async throws -> String { throw CodefluenceError.requestFailed(message: "App Attest is not supported") }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw CodefluenceError.requestFailed(message: "App Attest is not supported") }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { throw CodefluenceError.requestFailed(message: "App Attest is not supported") }
}

#if canImport(DeviceCheck)
struct SystemAppAttest: CodefluenceAppAttest {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
}
#endif

/// Daily activity signal and milestones (SPEC §29). Everything here is gated by the server:
/// until `GET /track/signal-config` answers `enabled: true` the SDK sends no identifiers and no proofs.
extension Codefluence {
    enum SignalKey {
        static let enabled = "codefluence.signal.enabled"
        static let checkedAt = "codefluence.signal.checkedAt"
        static let stoppedLeadId = "codefluence.signal.stoppedLeadId"
        static let attestKeyId = "codefluence.attest.keyId"
        static let attestRegisteredLeadId = "codefluence.attest.registeredLeadId"
        static let lastDay = "codefluence.signal.lastDay"
        static let sentMilestones = "codefluence.signal.sentMilestones"
        static let pendingMilestones = "codefluence.signal.pendingMilestones"
        static let attemptsDay = "codefluence.signal.attemptsDay"
        static let attempts = "codefluence.signal.attempts"
        static let adRevenueEnabled = "codefluence.signal.adRevenue"
    }

    /// How long a "capability" answer is reused. Disabled answers are re-checked rarely so a switched-off feature costs almost nothing.
    static let signalCapabilityTTL: TimeInterval = 6 * 3600
    static let maxSignalAttemptsPerDay = 3
    static let maxPendingMilestones = 10

    static func validMilestone(_ name: String) -> Bool {
        guard (1...40).contains(name.utf8.count) else { return false }
        return name.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    /// Records that the user reached a product milestone (for example `onboarded`). Names use letters, digits, `_`, `-` and `.`
    /// (up to 40 characters); anything else is ignored. The name is sent with the next attested daily signal and only when
    /// the campaign asks for milestones. Nothing leaves the device if the server has the feature turned off.
    public func trackMilestone(_ name: String, completion: ((CodefluenceActivitySignalOutcome) -> Void)? = nil) {
        guard Self.validMilestone(name) else { completion?(.skipped(reason: "invalid_milestone")); return }
        stateLock.lock()
        var pending = preferences.stringArray(forKey: SignalKey.pendingMilestones) ?? []
        let sent = preferences.stringArray(forKey: SignalKey.sentMilestones) ?? []
        if !pending.contains(name) && !sent.contains(name) && pending.count < Self.maxPendingMilestones { pending.append(name); preferences.set(pending, forKey: SignalKey.pendingMilestones) }
        stateLock.unlock()
        sendActivitySignalIfNeeded(completion: completion)
    }

    /// Sends today's activity signal for the confirmed referral if the server has the feature on, App Attest is available and
    /// no signal was sent today (a new milestone allows one more). Safe to call on every launch and foreground.
    /// Failures are returned as `.skipped` and never thrown.
    public func sendActivitySignalIfNeeded(completion: ((CodefluenceActivitySignalOutcome) -> Void)? = nil) {
        Task.detached { [weak self] in
            guard let self else { return }
            let outcome = await self.performActivitySignal(now: self.signalClock())
            if let completion { DispatchQueue.main.async { completion(outcome) } }
        }
    }

    static func kstDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    struct SignalIdentity { let host: URL; let key: String; let leadId: String; let token: String }

    func signalIdentity() -> SignalIdentity? {
        stateLock.lock(); defer { stateLock.unlock() }
        let normalized = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = apiHost, let scheme = host.scheme?.lowercased(), scheme == "http" || scheme == "https", host.host != nil, host.user == nil, host.query == nil, host.fragment == nil,
              host.path.isEmpty || host.path == "/", normalized.count > 3, normalized.hasPrefix("pk_"),
              let leadId = preferences.string(forKey: "codefluence.confirmedLeadId"), !leadId.isEmpty,
              let token = preferences.string(forKey: "codefluence.confirmedPurchaseAccountToken") ?? preferences.string(forKey: "codefluence.purchaseAccountToken"), !token.isEmpty else { return nil }
        return SignalIdentity(host: host, key: normalized, leadId: leadId, token: token)
    }

    func signalRequest(_ identity: SignalIdentity, path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: identity.host.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(identity.key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    func stopSignals(leadId: String) {
        stateLock.lock(); preferences.set(leadId, forKey: SignalKey.stoppedLeadId); stateLock.unlock()
    }

    func serverEnabled(_ identity: SignalIdentity, now: Date) async -> Bool {
        stateLock.lock()
        let checkedAt = preferences.double(forKey: SignalKey.checkedAt)
        let cached = preferences.object(forKey: SignalKey.enabled) as? Bool
        stateLock.unlock()
        if let cached, now.timeIntervalSince1970 - checkedAt < Self.signalCapabilityTTL, checkedAt <= now.timeIntervalSince1970 { return cached }
        // Only the public key is sent here: no user, install or device identifiers.
        guard let answer = try? await signalRequest(SignalIdentity(host: identity.host, key: identity.key, leadId: "", token: ""), path: "track/signal-config", method: "GET"), answer.status == 200 else { return false }
        let enabled = (answer.json["enabled"] as? Bool) == true
        let adRevenue = (answer.json["adRevenue"] as? Bool) == true
        stateLock.lock(); preferences.set(enabled, forKey: SignalKey.enabled); preferences.set(adRevenue, forKey: SignalKey.adRevenueEnabled); preferences.set(now.timeIntervalSince1970, forKey: SignalKey.checkedAt); stateLock.unlock()
        return enabled
    }

    static func sha256Data(_ text: String) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: Data(text.utf8)))
        #else
        return Data()
        #endif
    }
    func sha256(_ text: String) -> Data { Self.sha256Data(text) }

    func performActivitySignal(now: Date) async -> CodefluenceActivitySignalOutcome {
        guard let identity = signalIdentity() else { return .skipped(reason: "not_confirmed") }
        stateLock.lock()
        let stopped = preferences.string(forKey: SignalKey.stoppedLeadId) == identity.leadId
        let lastDay = preferences.string(forKey: SignalKey.lastDay)
        let pending = preferences.stringArray(forKey: SignalKey.pendingMilestones) ?? []
        let sent = Set(preferences.stringArray(forKey: SignalKey.sentMilestones) ?? [])
        let today = Self.kstDay(now)
        let attempts = preferences.string(forKey: SignalKey.attemptsDay) == today ? preferences.integer(forKey: SignalKey.attempts) : 0
        stateLock.unlock()
        if stopped { return .skipped(reason: "stopped") }
        let milestones = Array(Set(pending).subtracting(sent)).sorted().prefix(5).map { $0 }
        if lastDay == today && milestones.isEmpty { return .skipped(reason: "already_sent_today") }
        if attempts >= Self.maxSignalAttemptsPerDay { return .skipped(reason: "attempt_limit") }
        guard appAttest.isSupported else { return .skipped(reason: "attestation_unsupported") }
        guard await serverEnabled(identity, now: now) else { return .skipped(reason: "disabled") }

        stateLock.lock(); preferences.set(today, forKey: SignalKey.attemptsDay); preferences.set(attempts + 1, forKey: SignalKey.attempts); stateLock.unlock()
        do {
            // 1) one-time key registration per install
            let registration = try await ensureAttestKey(identity)
            guard case .ready(let activeKeyId) = registration else { if case .skipped(let reason) = registration { return .skipped(reason: reason) }; return .skipped(reason: "no_key") }

            // 2) today's signed signal
            guard let challenge = try await signalChallenge(identity, purpose: "signal") else { return .skipped(reason: "not_collecting") }
            let clientData = challenge + "\n" + milestones.joined(separator: ",")
            let assertion = try await appAttest.generateAssertion(activeKeyId, clientDataHash: sha256(clientData))
            let body: [String: Any] = ["leadId": identity.leadId, "purchaseAccountToken": identity.token, "challenge": challenge, "milestones": milestones,
                                       "proof": ["type": "app_attest", "keyId": activeKeyId, "assertion": assertion.base64EncodedString()]]
            let result = try await signalRequest(identity, path: "track/signal", body: body)
            if result.status == 429 { stateLock.lock(); preferences.set(Self.maxSignalAttemptsPerDay, forKey: SignalKey.attempts); stateLock.unlock(); return .skipped(reason: "rate_limited") }
            guard (200..<300).contains(result.status), (result.json["accepted"] as? Bool) == true else { return .skipped(reason: "rejected") }
            let attested = (result.json["attested"] as? Bool) == true
            if attested {
                stateLock.lock()
                preferences.set(today, forKey: SignalKey.lastDay)
                preferences.set(Array(sent.union(milestones)).sorted(), forKey: SignalKey.sentMilestones)
                preferences.set(pending.filter { !milestones.contains($0) }, forKey: SignalKey.pendingMilestones)
                stateLock.unlock()
            }
            return .sent(attested: attested)
        } catch {
            #if canImport(DeviceCheck)
            // The key is gone (for example after a restore): drop it so the next launch registers a new one.
            if let dcError = error as? DCError, dcError.code == .invalidKey {
                stateLock.lock(); preferences.removeObject(forKey: SignalKey.attestKeyId); preferences.removeObject(forKey: SignalKey.attestRegisteredLeadId); stateLock.unlock()
            }
            #endif
            return .skipped(reason: "error")
        }
    }

    enum AttestKeyState { case ready(String); case skipped(String) }

    /// Registers the install's App Attest key once per confirmed lead (shared by the daily signal and the ad revenue report).
    func ensureAttestKey(_ identity: SignalIdentity) async throws -> AttestKeyState {
        stateLock.lock()
        var keyId = preferences.string(forKey: SignalKey.attestKeyId)
        let registered = preferences.string(forKey: SignalKey.attestRegisteredLeadId) == identity.leadId
        stateLock.unlock()
        if keyId == nil || !registered {
            let challenge = try await signalChallenge(identity, purpose: "attest")
            guard let challenge else { return .skipped("not_collecting") }
            if keyId == nil || stateKeyBelongsToOtherLead() {
                keyId = try await appAttest.generateKey()
                stateLock.lock(); preferences.set(keyId, forKey: SignalKey.attestKeyId); stateLock.unlock()
            }
            guard let activeKeyId = keyId else { return .skipped("no_key") }
            let attestation = try await appAttest.attestKey(activeKeyId, clientDataHash: sha256(challenge))
            let result = try await signalRequest(identity, path: "track/signal-attest", body: ["leadId": identity.leadId, "purchaseAccountToken": identity.token, "challenge": challenge, "keyId": activeKeyId, "attestation": attestation.base64EncodedString()])
            if result.status == 409 { stopSignals(leadId: identity.leadId); return .skipped("key_conflict") }
            guard (200..<300).contains(result.status) else { return .skipped("attest_rejected") }
            stateLock.lock(); preferences.set(identity.leadId, forKey: SignalKey.attestRegisteredLeadId); stateLock.unlock()
        }
        guard let activeKeyId = keyId ?? stateString(SignalKey.attestKeyId) else { return .skipped("no_key") }
        return .ready(activeKeyId)
    }

    func stateString(_ key: String) -> String? { stateLock.lock(); defer { stateLock.unlock() }; return preferences.string(forKey: key) }

    /// A stored key that was registered for a different confirmed lead cannot be reused (one key per install and lead).
    func stateKeyBelongsToOtherLead() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let registeredLead = preferences.string(forKey: SignalKey.attestRegisteredLeadId) else { return false }
        return registeredLead != preferences.string(forKey: "codefluence.confirmedLeadId")
    }

    /// `nil` means the server does not want signals for this install (not a referred activation install, or the window closed).
    func signalChallenge(_ identity: SignalIdentity, purpose: String, stop: ((String) -> Void)? = nil) async throws -> String? {
        let stopHandler: (String) -> Void = stop ?? { [self] leadId in stopSignals(leadId: leadId) }
        let result = try await signalRequest(identity, path: "track/signal-challenge", body: ["leadId": identity.leadId, "purchaseAccountToken": identity.token, "purpose": purpose])
        // 404: the server does not know this install. 409: the feature was switched off meanwhile, so ask again later instead of stopping for good.
        if result.status == 409 { stateLock.lock(); preferences.set(false, forKey: SignalKey.enabled); preferences.set(signalClock().timeIntervalSince1970, forKey: SignalKey.checkedAt); stateLock.unlock(); return nil }
        if result.status == 404 { stopHandler(identity.leadId); return nil }
        guard (200..<300).contains(result.status) else { throw CodefluenceError.requestFailed(message: "challenge failed") }
        if (result.json["collect"] as? Bool) == false { stopHandler(identity.leadId); return nil }
        guard let challenge = result.json["challenge"] as? String, !challenge.isEmpty else { throw CodefluenceError.requestFailed(message: "challenge missing") }
        return challenge
    }
}
