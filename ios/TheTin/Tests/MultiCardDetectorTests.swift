import CoreImage
import XCTest
@testable import TheTin

final class MultiCardDetectorTests: XCTestCase {

    /// A synthetic "binder page": nine light card-shaped rectangles on a dark ground. Vision's
    /// rectangles request finds high-contrast quads reliably, which is all this asserts — matching
    /// accuracy is Task 3's problem and real-photo accuracy is Task 8's.
    private func syntheticPage(rows: Int, cols: Int) -> CIImage {
        let cardW: CGFloat = 330, cardH: CGFloat = 460, gap: CGFloat = 40
        let w = CGFloat(cols) * (cardW + gap) + gap
        let h = CGFloat(rows) * (cardH + gap) + gap
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        for r in 0..<rows { for c in 0..<cols {
            let rect = CGRect(x: gap + CGFloat(c) * (cardW + gap),
                              y: gap + CGFloat(r) * (cardH + gap),
                              width: cardW, height: cardH)
            let card = CIImage(color: .white).cropped(to: rect)
            image = card.composited(over: image)
        } }
        return image
    }

    /// A page whose pockets are not all the same way up — a card lying sideways in a case, or one
    /// occluded enough that its quad comes out wide. `landscape` gives the orientation of each
    /// pocket in reading order; every card sits centred in an identical square box, so position
    /// carries no information about orientation.
    private func mixedPage(_ landscape: [Bool], cols: Int = 3) -> CIImage {
        let box: CGFloat = 520, gap: CGFloat = 40
        let rows = Int(ceil(Double(landscape.count) / Double(cols)))
        let w = CGFloat(cols) * (box + gap) + gap
        let h = CGFloat(rows) * (box + gap) + gap
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        for (i, isLandscape) in landscape.enumerated() {
            let cw: CGFloat = isLandscape ? 460 : 330
            let ch: CGFloat = isLandscape ? 330 : 460
            let x = gap + CGFloat(i % cols) * (box + gap) + (box - cw) / 2
            let y = gap + CGFloat(i / cols) * (box + gap) + (box - ch) / 2
            image = CIImage(color: .white).cropped(to: CGRect(x: x, y: y, width: cw, height: ch))
                .composited(over: image)
        }
        return image
    }

    /// `MultiCardDetector` only streams — the array-returning form it used to expose had no
    /// production callers and existed purely for these tests, which is the shape of live-looking
    /// code this project keeps getting bitten by. The tests collect for themselves.
    private func collect(_ ci: CIImage, context: CIContext = CIContext()) -> [DetectedCell] {
        var out: [DetectedCell] = []
        MultiCardDetector.forEachCell(in: ci, context: context) { out.append($0) }
        return out
    }

    private func collect(_ ci: CIImage, context: CIContext = CIContext(),
                         orienter: (CIImage, CIContext, Int?) -> (image: CIImage, degrees: Int)?)
        -> [DetectedCell] {
        var out: [DetectedCell] = []
        MultiCardDetector.forEachCell(in: ci, context: context, orienter: orienter) { out.append($0) }
        return out
    }

    func testFindsEveryCardOnASyntheticPage() throws {
        let ci = syntheticPage(rows: 3, cols: 3)
        let cells = collect(ci)
        XCTAssertGreaterThanOrEqual(cells.count, 8, "expected ~9 pockets, got \(cells.count)")
        XCTAssertLessThanOrEqual(cells.count, 9, "duplicates were not merged")
    }

    func testEveryCellIsACanonicalPlate() throws {
        let cells = collect(syntheticPage(rows: 1, cols: 2))
        let cell = try XCTUnwrap(cells.first)
        XCTAssertEqual(cell.plate.width, Int(kFPCanonW))
        XCTAssertEqual(cell.plate.height, Int(kFPCanonH))
        XCTAssertEqual(cell.plate.pixels.count, cell.plate.bytesPerRow * cell.plate.height)
    }

    func testCellsCarryTheirQuadSoTheyCanBeDrawnOnThePhoto() throws {
        let cells = collect(syntheticPage(rows: 1, cols: 2))
        XCTAssertEqual(cells.count, 2)
        let centers = cells.map { ScoredQuad(quad: $0.quad, confidence: 0).center.x }
        XCTAssertNotEqual(centers[0], centers[1], "both cells reported the same position")
    }

    func testAnEmptyImageYieldsNoCells() {
        let blank = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertTrue(collect(blank).isEmpty)
    }

    /// The whole point of `MultiCardDetector` is that `OrientationNormalizer.orientUpright`'s
    /// expensive scoring (two full-resolution renders + two Vision text passes) runs ONCE per
    /// photo, not once per card — paying it 40 times is what makes the feature unusable on an
    /// A10. Counts the real calls through an injected orienter rather than trusting the source.
    func testOrientationScoringRunsOnceAndIsReusedForEveryOtherCell() throws {
        var preferredArgs: [Int?] = []
        let countingOrienter: (CIImage, CIContext, Int?) -> (image: CIImage, degrees: Int)? = { corrected, context, preferred in
            preferredArgs.append(preferred)
            return OrientationNormalizer.orientUpright(corrected, context: context, preferred: preferred)
        }

        let cells = collect(syntheticPage(rows: 3, cols: 3), orienter: countingOrienter)

        XCTAssertGreaterThanOrEqual(cells.count, 8, "expected ~9 pockets, got \(cells.count)")
        let nilCalls = preferredArgs.filter { $0 == nil }.count
        XCTAssertEqual(nilCalls, 1, "the expensive scoring pass must run exactly once per photo, ran \(nilCalls) times")
        XCTAssertTrue(preferredArgs.dropFirst().allSatisfy { $0 != nil },
                      "every cell after the first must reuse the shared rotation instead of re-scoring")
    }

    /// ⚠️ The test above cannot see the failure this one exists for, because its page is uniformly
    /// portrait: a non-nil hint is not necessarily a USED hint. `orientUpright` ignores `preferred`
    /// unless it is one of the candidates for that image, and the candidates are [90, 270] for a
    /// landscape-extent correction against [0, 180] for a portrait one. With a single shared
    /// rotation, one sideways card mid-page poisons the hint for every remaining portrait cell and
    /// each pays the full scoring again — the exact cost this file exists to avoid, degrading
    /// silently. So this counts calls where the hint was UNUSABLE, which is what actually costs
    /// two renders and two Vision text passes.
    /// ⚠️ Counting calls is NOT enough to catch this, and that is worth knowing before anyone
    /// "simplifies" the assertion: `QuadFilter.select` orders by confidence, identical shapes score
    /// identically, so the two orientations arrive in two contiguous runs and even a single shared
    /// hint costs exactly two scorings on a synthetic page. Verified — a call-count version of this
    /// test passed against the one-hint implementation. Only the per-call contract distinguishes
    /// them: every cell must receive the rotation established by the previous cell OF ITS OWN
    /// ORIENTATION, and nil if there has not been one. With a single shared hint the first cell of
    /// the second class is handed the other class's rotation instead — a value `orientUpright`
    /// cannot use, so it silently re-scores. (Mutation-checked: reverting to one shared rotation
    /// fails here with "portrait got Optional(90), expected nil".) On a real page (glare bands,
    /// occluded and sideways cards
    /// interleaved with upright ones) the classes are NOT contiguous and the cost is per cell.
    func testEveryCellIsHintedFromItsOwnOrientationNotWhicheverCameLast() throws {
        var lastByClass: [Bool: Int] = [:]
        var wrongHints: [String] = []
        var classesSeen: Set<Bool> = []
        let orienter: (CIImage, CIContext, Int?) -> (image: CIImage, degrees: Int)? = { corrected, context, preferred in
            let isLandscape = corrected.extent.width > corrected.extent.height
            if preferred != lastByClass[isLandscape] {
                wrongHints.append("\(isLandscape ? "landscape" : "portrait") got "
                                  + "\(String(describing: preferred)), expected "
                                  + "\(String(describing: lastByClass[isLandscape]))")
            }
            classesSeen.insert(isLandscape)
            let out = OrientationNormalizer.orientUpright(corrected, context: context, preferred: preferred)
            if let out { lastByClass[isLandscape] = out.degrees }
            return out
        }

        let cells = collect(mixedPage([false, true, false, false, true, false]), orienter: orienter)

        XCTAssertGreaterThanOrEqual(cells.count, 5, "expected ~6 pockets, got \(cells.count)")
        XCTAssertEqual(classesSeen.count, 2,
                       "the page must present both orientations or this test proves nothing")
        XCTAssertEqual(wrongHints, [], "a cell was hinted from the wrong orientation")
    }
}
