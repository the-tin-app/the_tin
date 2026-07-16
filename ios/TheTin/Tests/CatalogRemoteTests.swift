import XCTest
@testable import TheTin

/// The catalog is served publicly via the Firebase Storage rules layer (the org blocks public
/// GCS buckets), which requires the Firebase Storage download endpoint URL format:
/// `https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<percent-encoded-object-path>?alt=media`.
/// The object path is ONE encoded segment after `/o/` — every `/` in it must become `%2F`.
final class CatalogRemoteTests: XCTestCase {
    func testDownloadURLEncodesManifestPath() throws {
        let url = try XCTUnwrap(HTTPCatalogRemote.downloadURL(base: AppConfig.catalogBaseURL, path: "catalog/manifest.json"))
        XCTAssertEqual(
            url.absoluteString,
            "https://firebasestorage.googleapis.com/v0/b/hobby-tcg.firebasestorage.app/o/catalog%2Fmanifest.json?alt=media"
        )
    }

    func testDownloadURLEncodesArtifactPath() throws {
        let url = try XCTUnwrap(HTTPCatalogRemote.downloadURL(base: AppConfig.catalogBaseURL, path: "catalog/catalog-v1.sqlite.gz"))
        XCTAssertEqual(
            url.absoluteString,
            "https://firebasestorage.googleapis.com/v0/b/hobby-tcg.firebasestorage.app/o/catalog%2Fcatalog-v1.sqlite.gz?alt=media"
        )
    }

    func testDownloadURLEncodesNestedDeltaPath() throws {
        let url = try XCTUnwrap(HTTPCatalogRemote.downloadURL(base: AppConfig.catalogBaseURL, path: "catalog/deltas/prices-2026-07-06.json.gz"))
        XCTAssertEqual(
            url.absoluteString,
            "https://firebasestorage.googleapis.com/v0/b/hobby-tcg.firebasestorage.app/o/catalog%2Fdeltas%2Fprices-2026-07-06.json.gz?alt=media"
        )
    }
}
