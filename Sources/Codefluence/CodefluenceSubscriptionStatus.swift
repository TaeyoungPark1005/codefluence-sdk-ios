import Foundation

/// Read-only subscription status (C3). This is a normalized **view** of adapter
/// events, not an entitlement decision. Do not gate paid features on it; use your
/// payment provider's entitlement/receipt check for access control.
public struct CodefluenceSubscriptionStatus: Equatable {
    public enum State: String, Equatable {
        case none, active, grace, cancelled, expired, refunded
    }

    public struct Event: Equatable {
        public enum Kind: String, Equatable {
            case started, renewed, cancelled, refunded, grace, expired
        }
        /// Known event kind, or `nil` for a forward-compatible unknown type.
        public let kind: Kind?
        /// Raw server type string, preserved even when `kind` is unknown.
        public let rawType: String
        public let occurredAt: String
        public let source: String
    }

    public let state: State
    public let sandbox: Bool
    public let updatedAt: String?
    public let events: [Event]
}
