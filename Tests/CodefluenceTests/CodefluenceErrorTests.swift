import XCTest
import Foundation
@testable import Codefluence

/// B6: Structured public error. Numeric codes must stay stable and bridge to the
/// historical `Codefluence` NSError domain/code so existing callbacks keep working.
final class CodefluenceErrorTests: XCTestCase {
    func testEachCaseKeepsItsHistoricalNumericCode() {
        let mapping: [(CodefluenceError, Int)] = [
            (.requestFailed(message: "x"), 1),
            (.missingReferralInput, 2),
            (.declined, 3),
            (.attributionForDifferentCustomer, 4),
            (.retryIdentityMismatch, 5),
            (.noPendingConfirmation, 6),
            (.requestInProgress, 7),
            (.alreadyPresenting, 8),
            (.presenterOrCustomerRequired, 9),
            (.decisionAlreadyMade, 10),
            (.notConfigured(message: "y"), 11),
            (.noSubscriptionReference, 12),
            (.subscriptionNotFound, 13)
        ]
        for (error, expected) in mapping {
            XCTAssertEqual(error.code, expected)
        }
    }

    func testBridgesToCodefluenceNSErrorDomainWithSameCodeAndMessage() {
        let error = CodefluenceError.notConfigured(message: "call configure")
        let nsError = error as NSError
        XCTAssertEqual(nsError.domain, "Codefluence")
        XCTAssertEqual(nsError.code, 11)
        XCTAssertEqual(nsError.localizedDescription, "call configure")
    }

    func testOnlyRequestFailedIsRetryable() {
        XCTAssertTrue(CodefluenceError.requestFailed(message: "timeout").isRetryable)
        for error: CodefluenceError in [
            .missingReferralInput, .declined, .attributionForDifferentCustomer,
            .retryIdentityMismatch, .noPendingConfirmation, .requestInProgress,
            .alreadyPresenting, .presenterOrCustomerRequired, .decisionAlreadyMade,
            .notConfigured(message: "z"), .noSubscriptionReference, .subscriptionNotFound
        ] {
            XCTAssertFalse(error.isRetryable, "\(error) must not be retryable")
        }
    }

    func testResultCallbacksCanSwitchOnStructuredCase() {
        let suite = "codefluence-error-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let sdk = Codefluence(preferences: preferences, session: .shared)
        let completed = expectation(description: "structured error surfaces")
        sdk.confirm(clickToken: "", appUserId: "") { result in
            switch result {
            case .success:
                XCTFail("blank input should not succeed")
            case .failure(let error):
                guard let structured = error as? CodefluenceError else {
                    XCTFail("error is not CodefluenceError: \(error)")
                    return
                }
                XCTAssertEqual(structured, .missingReferralInput)
                XCTAssertEqual((error as NSError).code, 2)
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }
}
