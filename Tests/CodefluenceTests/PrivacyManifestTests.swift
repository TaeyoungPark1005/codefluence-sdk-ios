import XCTest
import Foundation
@testable import Codefluence

/// A4: UIPasteboard is not an Apple Required Reason API, so the manifest must
/// declare UserDefaults (CA92.1) only and never add a pasteboard category.
final class PrivacyManifestTests: XCTestCase {
    private func loadManifest() throws -> [String: Any] {
        guard let url = PrivacyManifestResource.url() else {
            throw XCTSkip("PrivacyInfo.xcprivacy is not bundled in this build")
        }
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// The SDK sends Apple-signed purchase records and the app's customer ID to the Codefluence
    /// server to attribute referral purchases, so both are declared as collected and linked.
    func testPrivacyManifestDeclaresPurchaseHistoryAndUserID() throws {
        let manifest = try loadManifest()
        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        for type in ["NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeUserID"] {
            let entry = try XCTUnwrap(collected.first { ($0["NSPrivacyCollectedDataType"] as? String) == type }, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], ["NSPrivacyCollectedDataTypePurposeDeveloperAdvertising"])
        }
    }

    func testPrivacyManifestDeclaresUserDefaultsReasonCA921() throws {
        let manifest = try loadManifest()
        let apiTypes = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let userDefaults = apiTypes.first { ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryUserDefaults" }
        let reasons = try XCTUnwrap((userDefaults?["NSPrivacyAccessedAPITypeReasons"]) as? [String])
        XCTAssertEqual(reasons, ["CA92.1"])
    }

    func testPrivacyManifestDoesNotDeclareAnyPasteboardRequiredReasonCategory() throws {
        let manifest = try loadManifest()
        let apiTypes = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = apiTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        for category in declared {
            XCTAssertFalse(category.lowercased().contains("pasteboard"),
                           "UIPasteboard is not a Required Reason API category; found \(category)")
            XCTAssertFalse(category.lowercased().contains("clipboard"),
                           "Clipboard is not a Required Reason API category; found \(category)")
        }
    }

    func testPrivacyManifestOnlyUsesKnownRequiredReasonCategories() throws {
        let manifest = try loadManifest()
        let apiTypes = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let known: Set<String> = [
            "NSPrivacyAccessedAPICategoryFileTimestamp",
            "NSPrivacyAccessedAPICategorySystemBootTime",
            "NSPrivacyAccessedAPICategoryDiskSpace",
            "NSPrivacyAccessedAPICategoryActiveKeyboards",
            "NSPrivacyAccessedAPICategoryUserDefaults"
        ]
        for entry in apiTypes {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertTrue(known.contains(category), "unexpected Required Reason category: \(category)")
        }
    }
}
