import Foundation

/// Internal accessor to the module's bundled privacy manifest. Tests use this to
/// verify the Required Reason API declarations without duplicating bundle lookup.
enum PrivacyManifestResource {
    static func url() -> URL? {
        Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }
}
