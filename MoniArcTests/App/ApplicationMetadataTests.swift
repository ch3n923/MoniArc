import Foundation
import XCTest

final class ApplicationMetadataTests: XCTestCase {
    func testReleaseIdentityMetadata() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)

        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.zhengzipeng.MoniArc")
        XCTAssertEqual(info["CFBundleName"] as? String, "MoniArc")
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(version.range(of: #"^[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression))
        XCTAssertNotNil(build.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression))
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertEqual(
            info["LSApplicationCategoryType"] as? String,
            "public.app-category.developer-tools"
        )
    }

    func testBundledPrivacyManifestDeclaresNoCollectionOrTracking() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let manifest = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertTrue(try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [Any]).isEmpty)
        XCTAssertTrue(try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [Any]).isEmpty)
    }
}
