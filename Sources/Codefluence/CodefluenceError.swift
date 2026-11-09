import Foundation

/// Structured public error for the Codefluence SDK (B6).
///
/// Each case keeps the historical numeric `code` so callers that inspect
/// `(error as NSError).code` keep working. `CustomNSError` bridges the case to
/// the `Codefluence` error domain with the same code and localized message, so
/// existing `Result<_, Error>` callbacks can switch on `CodefluenceError` or
/// continue to read the `NSError` code. `isRetryable` tells a host whether a
/// manual `retryPendingConfirmation` (or the automatic queue) can make progress.
public enum CodefluenceError: Error, Equatable {
    /// code 1 — a network/HTTP request failed or returned an invalid body.
    case requestFailed(message: String)
    /// code 2 — confirm requires a non-empty referral token and customer ID.
    case missingReferralInput
    /// code 3 — a saved "No" decision cannot be bypassed.
    case declined
    /// code 4 — a completed/again-resolved attribution belongs to another customer.
    case attributionForDifferentCustomer
    /// code 5 — a retry changed the accepted token or customer ID.
    case retryIdentityMismatch
    /// code 6 — there is no accepted, unfinished confirmation to retry.
    case noPendingConfirmation
    /// code 7 — a confirmation request is already in progress.
    case requestInProgress
    /// code 8 — a prompt/attribution is already being presented or resolved.
    case alreadyPresenting
    /// code 9 — a visible presenter and/or stable customer ID is required.
    case presenterOrCustomerRequired
    /// code 10 — a decision already exists for this install.
    case decisionAlreadyMade
    /// code 11 — the SDK is not configured (missing/invalid pk_ key or apiHost).
    case notConfigured(message: String)
    /// code 12 — no saved leadId/purchaseAccountToken is available to read status.
    case noSubscriptionReference
    /// code 13 — the server has no subscription record for the saved references.
    case subscriptionNotFound
    /// code 14 — the server rejected this install's confirmation because the customer was already confirmed by another install (for example after a reinstall without proof, or an ID collision). Retrying will not help.
    case confirmationRejected

    /// Stable numeric code, unchanged from the pre-B6 SDK.
    public var code: Int {
        switch self {
        case .requestFailed: return 1
        case .missingReferralInput: return 2
        case .declined: return 3
        case .attributionForDifferentCustomer: return 4
        case .retryIdentityMismatch: return 5
        case .noPendingConfirmation: return 6
        case .requestInProgress: return 7
        case .alreadyPresenting: return 8
        case .presenterOrCustomerRequired: return 9
        case .decisionAlreadyMade: return 10
        case .notConfigured: return 11
        case .noSubscriptionReference: return 12
        case .subscriptionNotFound: return 13
        case .confirmationRejected: return 14
        }
    }

    /// Whether retrying the same request can plausibly succeed later. Only
    /// transient transport/HTTP failures are retryable.
    public var isRetryable: Bool {
        switch self {
        case .requestFailed: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .requestFailed(let message): return message
        case .missingReferralInput: return "A referral token and stable customer ID are required"
        case .declined: return "Referral confirmation was declined"
        case .attributionForDifferentCustomer: return "Referral attribution belongs to a different customer"
        case .retryIdentityMismatch: return "Retry must preserve the accepted token and customer ID"
        case .noPendingConfirmation: return "No accepted pending confirmation is available"
        case .requestInProgress: return "Referral confirmation is already in progress"
        case .alreadyPresenting: return "Referral confirmation is already being presented"
        case .presenterOrCustomerRequired: return "A visible presenter and stable customer ID are required"
        case .decisionAlreadyMade: return "Referral confirmation already has a decision"
        case .notConfigured(let message): return message
        case .noSubscriptionReference: return "No confirmed referral is available to read subscription status"
        case .subscriptionNotFound: return "No subscription record was found for this customer"
        case .confirmationRejected: return "Referral confirmation was rejected: this customer was already confirmed by another install"
        }
    }
}

extension CodefluenceError: CustomNSError {
    public static var errorDomain: String { "Codefluence" }
    public var errorCode: Int { code }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
}
