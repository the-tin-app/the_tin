import Foundation
import Observation

/// A pseudo-infinite source of cards. `page(_:)` is pure and nonisolated so it can run
/// off the main thread; the same index always yields the same cards (deterministic paging).
protocol CardStream: Sendable {
    func page(_ index: Int) -> [CardRecord]
}

/// MainActor driver that accumulates a stream's pages, dedups by card id within a session,
/// and computes each page off the main thread.
@MainActor @Observable
final class StreamPager {
    private(set) var cards: [CardRecord] = []
    private var nextIndex = 0
    private var seen: Set<String> = []
    private var exhaustedRuns = 0
    private var isLoading = false
    private let stream: CardStream

    init(stream: CardStream) { self.stream = stream }

    /// Load the next page (off-main), dropping any card already shown this session.
    /// Stops paging after two consecutive empty pages (stream exhausted). Non-reentrant:
    /// overlapping calls (StreamView fires a Task per near-tail swipe) are rejected by the
    /// `isLoading` guard, and the page index is reserved synchronously before the await so
    /// concurrent calls can never compute the same page and skip the next one.
    func loadNextPage() async {
        guard !isLoading, exhaustedRuns < 2 else { return }
        isLoading = true
        defer { isLoading = false }
        let index = nextIndex
        nextIndex += 1
        let stream = self.stream
        let fresh = await Task.detached(priority: .userInitiated) {
            stream.page(index)
        }.value
        let novel = fresh.filter { seen.insert($0.id).inserted }
        if fresh.isEmpty { exhaustedRuns += 1 } else { exhaustedRuns = 0 }
        cards.append(contentsOf: novel)
    }
}
