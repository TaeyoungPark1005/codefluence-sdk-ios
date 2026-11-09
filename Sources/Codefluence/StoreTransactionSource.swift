import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Reads App Store data the SDK reports to the server. Every value is an Apple-signed JWS;
/// the server verifies the signature, so nothing here is trusted on its own.
public protocol StoreTransactionSource {
    /// The signed AppTransaction (carries `appTransactionId`). Sent once with the referral confirmation.
    func appTransactionJWS() async -> String?
    /// Every verified transaction for this app, regardless of which code (StoreKit, RevenueCat, ...) made the purchase.
    func signedTransactions() async -> [(transactionId: String, jws: String)]
}

/// Used by package tests and platforms without StoreKit.
struct EmptyStoreTransactionSource: StoreTransactionSource {
    func appTransactionJWS() async -> String? { nil }
    func signedTransactions() async -> [(transactionId: String, jws: String)] { [] }
}

#if canImport(StoreKit)
struct SystemStoreTransactionSource: StoreTransactionSource {
    func appTransactionJWS() async -> String? {
        guard #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) else { return nil }
        return try? await AppTransaction.shared.jwsRepresentation
    }

    func signedTransactions() async -> [(transactionId: String, jws: String)] {
        guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) else { return [] }
        var out: [(transactionId: String, jws: String)] = []
        for await result in Transaction.all {
            // Refunded/revoked purchases are not sales; the server also refuses them.
            if case .verified(let transaction) = result, transaction.revocationDate == nil { out.append((String(transaction.id), result.jwsRepresentation)) }
        }
        return out
    }
}
#endif
