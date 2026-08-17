import SwiftUI
import XCTest
@testable import TheTin

/// The centring editor's readout must be **one fixed height, whatever it says**.
///
/// It sits directly above the picture in the editor's `VStack`, and the picture is a
/// `GeometryReader` taking whatever height is left. So a readout that resizes reflows the stack,
/// which recomputes the plate-pixels-to-points factor, which moves all eight lines — while one of
/// them is under the user's finger. That is not a cosmetic wobble; it is the drag juddering
/// (Tomas, device, 2026-08-17), and it is invisible in a screenshot.
///
/// Measured, never derived: adding the point sizes up is how the binder's "mystery gap" happened.
@MainActor
final class CenteringReadoutTests: XCTestCase {
    /// A narrow phone — the width where the idle sentence is most likely to want a second line.
    private let narrow = CGSize(width: 320, height: 900)

    /// Every state the readout can be in, including the ratios with the most and fewest
    /// characters, and the longest line label.
    private var states: [(String, CenteringReadout)] {
        [
            ("idle", CenteringReadout(summary: "50/50 L-R · 50/50 T-B",
                                      spoken: "", active: nil)),
            ("shortest ratio", CenteringReadout(summary: "5/95 L-R · 5/95 T-B",
                                                spoken: "", active: nil)),
            ("longest ratio", CenteringReadout(summary: "100/0 L-R · 100/0 T-B",
                                               spoken: "", active: nil)),
            ("dragging, 1 digit", CenteringReadout(
                summary: "55/45 L-R · 51/49 T-B", spoken: "",
                active: (label: "Left border", px: 4, isOuter: false))),
            ("dragging, 3 digits + longest label", CenteringReadout(
                summary: "9/91 L-R · 100/0 T-B", spoken: "",
                active: (label: "Bottom card edge", px: 487, isOuter: true))),
        ]
    }

    func testTheReadoutIsOneFixedHeight() throws {
        var seen: [(String, CGFloat)] = []
        for (name, view) in states {
            let size = try XCTUnwrap(sizeThatFits(view, in: narrow), name)
            seen.append((name, size.height))
        }
        let heights = Set(seen.map { $0.1 })
        XCTAssertEqual(heights.count, 1,
                       "the readout changes height between states, which moves every line "
                       + "mid-drag: \(seen.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))")
        // Deliberately NOT asserted against a hard-coded constant: the height may be whatever the
        // type size makes it. What must never vary is the height BETWEEN states.
    }

    /// The specific transition the drag makes on every single gesture: nothing selected → a line
    /// selected. This was previously a `ViewBuilder` if/else with an `.animation` on it, so it
    /// animated a size change for 150ms at the start of every drag.
    func testSelectingALineDoesNotResizeTheReadout() throws {
        let idle = try XCTUnwrap(sizeThatFits(states[0].1, in: narrow))
        let dragging = try XCTUnwrap(sizeThatFits(states[4].1, in: narrow))
        XCTAssertEqual(idle.height, dragging.height, accuracy: 0.5,
                       "picking up a line resizes the readout — the picture below it reflows "
                       + "and every line shifts as the drag begins")
    }

    /// Larger text may make the box taller — that is a layout the user chose, and it must grow
    /// rather than clip. What it must not do is make the height depend on WHICH state the readout
    /// is in, or the judder comes back for exactly the people least able to tolerate it.
    func testTheHeightStaysConstantAtLargerDynamicType() throws {
        for size in [DynamicTypeSize.large, .xxLarge, .accessibility3] {
            let heights = try states.map { name, view -> CGFloat in
                try XCTUnwrap(sizeThatFits(view.dynamicTypeSize(size), in: narrow), name).height
            }
            XCTAssertEqual(Set(heights).count, 1,
                           "readout height varies by state at \(size): \(heights)")
        }
    }

    private func sizeThatFits<V: View>(_ view: V, in frame: CGSize) -> CGSize? {
        let host = UIHostingController(rootView: view.frame(width: frame.width))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
    }
}
