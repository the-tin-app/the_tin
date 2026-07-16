import XCTest
@testable import TheTin

final class CardImagePrefetcherTests: XCTestCase {
    /// Each unique URL is fetched exactly once, even across calls and within a batch — so swiping
    /// back and forth doesn't re-hit the network for art already warmed into the cache.
    @MainActor
    func testPrefetchDedupesUrlsWithinAndAcrossCalls() {
        var fetched: [URL] = []
        let prefetcher = CardImagePrefetcher(fetch: { fetched.append($0) })
        let a = URL(string: "https://img/a.webp")!
        let b = URL(string: "https://img/b.webp")!
        let c = URL(string: "https://img/c.webp")!

        prefetcher.prefetch([a, b, a])   // duplicate a within the batch is skipped
        prefetcher.prefetch([a, c])      // a already requested earlier is skipped

        XCTAssertEqual(fetched, [a, b, c], "each URL fetched once, in first-seen order")
    }
}
