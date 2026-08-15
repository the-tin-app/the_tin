import SwiftUI
import TipKit

/// Measures a card's centring by letting the user place eight lines themselves, on a picture of
/// the card they actually scanned: the card's cut edge and the printed border's inner edge, on
/// each side. The border width is the gap between the pair, and the ratio of opposite widths is
/// the measurement.
///
/// Eight rather than four because four assumed the picture's edge was the card's edge, and it
/// isn't — that assumption is most of why automatic detection read 90/10 on real photos
/// (`fingerprint/eval/centering_check.swift`, 2026-08-14). The picture is deliberately cropped
/// wider than the card (`EditorPlate.margin`) so the cut edge is visible and reachable rather than
/// pinned against the boundary.
///
/// `CenteringMeter` only seeds the inner lines. The value that reaches the row is the one a person
/// placed and looked at.
struct CenteringEditorView: View {
    let plate: UIImage
    /// Where the lines start. Nil seeds the inner pair from the detector and puts the outer pair
    /// on the card's expected edge, given the known crop margin.
    let initial: Centering?
    let onSave: (Centering) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Every line as an inset in PLATE pixels from its own edge — the units `Centering` stores, so
    /// what is dragged is what is saved with no rounding trip through view coordinates.
    @State private var inset: [Line: CGFloat] = [:]
    @State private var seeded = false
    /// The dragged line's value when its gesture began. See the gesture below.
    @State private var dragOrigin: CGFloat?
    /// The line under the finger, or the last one moved — drives the readout and the highlight.
    @State private var active: Line?

    @State private var zoom: CGFloat = 1
    @State private var zoomOrigin: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panOrigin: CGSize?

    /// A border can be a couple of pixels wide on a 1400px picture, so the useful range goes well
    /// past what a photo viewer needs — at 6× a single plate pixel is a comfortable target.
    private static let zoomRange: ClosedRange<CGFloat> = 1...6

    enum Line: Hashable, CaseIterable {
        case outerLeft, innerLeft, outerRight, innerRight
        case outerTop, innerTop, outerBottom, innerBottom

        var isVertical: Bool {
            switch self {
            case .outerLeft, .innerLeft, .outerRight, .innerRight: return true
            default: return false
            }
        }
        var isOuter: Bool {
            switch self {
            case .outerLeft, .outerRight, .outerTop, .outerBottom: return true
            default: return false
            }
        }
        /// Which edge the inset is measured from.
        var alignment: Alignment {
            switch self {
            case .outerLeft, .innerLeft: return .leading
            case .outerRight, .innerRight: return .trailing
            case .outerTop, .innerTop: return .top
            case .outerBottom, .innerBottom: return .bottom
            }
        }
        var side: String {
            switch self {
            case .outerLeft, .innerLeft: return "Left"
            case .outerRight, .innerRight: return "Right"
            case .outerTop, .innerTop: return "Top"
            case .outerBottom, .innerBottom: return "Bottom"
            }
        }
        var label: String { "\(side) \(isOuter ? "card edge" : "border")" }
    }

    /// Cyan and magenta because they have to stay legible over yellow borders, blue holo, black
    /// full-arts and a wooden table alike — neither turns up much in card art, and they read as
    /// two different things at a glance rather than two shades of one.
    private static let outerColor = Color.cyan
    private static let innerColor = Color(red: 1, green: 0.2, blue: 0.8)

    private var plateSize: CGSize {
        CGSize(width: plate.size.width * plate.scale, height: plate.size.height * plate.scale)
    }

    private func px(_ line: Line) -> CGFloat { inset[line] ?? 0 }

    private var current: Centering {
        Centering(outerLeft: Int(px(.outerLeft).rounded()), innerLeft: Int(px(.innerLeft).rounded()),
                  outerRight: Int(px(.outerRight).rounded()), innerRight: Int(px(.innerRight).rounded()),
                  outerTop: Int(px(.outerTop).rounded()), innerTop: Int(px(.innerTop).rounded()),
                  outerBottom: Int(px(.outerBottom).rounded()), innerBottom: Int(px(.innerBottom).rounded()))
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(current.summary)
                .font(.title3.monospacedDigit().weight(.semibold))
                .accessibilityLabel(current.spokenSummary)
            statusChip
            // Shown once, on the first visit: without it the lens bow reads as the app being
            // wrong, on the one screen whose whole job is to be trusted.
            TipView(CenteringLensBowTip())
            picture
            legend
        }
        .padding()
        .navigationTitle("Centering")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { onSave(current); dismiss() }.fontWeight(.semibold)
            }
        }
        .onAppear(perform: seed)
    }

    /// Names the line being moved and its current inset. Without it, eight lines of two colours
    /// still leave "which one did I just grab?" unanswered the moment a finger covers the line.
    private var statusChip: some View {
        Group {
            if let active {
                HStack(spacing: 6) {
                    Circle().fill(active.isOuter ? Self.outerColor : Self.innerColor)
                        .frame(width: 9, height: 9)
                    Text(active.label).fontWeight(.medium)
                    Text("\(Int(px(active).rounded())) px").foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                // Says where to line up, not just what to drag: the lens bows the card's edges
                // slightly, so a straight line fits the middle of an edge or its ends, and
                // matching every line at the middle is what keeps the bow out of the answer.
                Text("Drag the handles — match each at the middle of its edge")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .animation(.easeInOut(duration: 0.15), value: active)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach([true, false], id: \.self) { outer in
                HStack(spacing: 5) {
                    Capsule().fill(outer ? Self.outerColor : Self.innerColor)
                        .frame(width: 16, height: 3)
                    Text(outer ? "Card edge" : "Printed border").font(.caption2)
                }
            }
            Spacer()
            if zoom > 1 {
                Button("Reset zoom") { withAnimation { zoom = 1; pan = .zero } }
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var picture: some View {
        GeometryReader { geo in
            // `base` maps plate pixels to points at zoom 1; the live factor is `base * zoom`, and
            // every drag delta is divided by it so a finger moves a line by what it looks like.
            let base = min(geo.size.width / plateSize.width, geo.size.height / plateSize.height)
            let shown = CGSize(width: plateSize.width * base, height: plateSize.height * base)
            ZStack {
                Image(uiImage: plate).resizable().frame(width: shown.width, height: shown.height)
                ForEach(Line.allCases, id: \.self) { line in
                    lineView(line, in: shown, scale: base * zoom)
                }
            }
            .frame(width: shown.width, height: shown.height)
            .scaleEffect(zoom)
            .offset(pan)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            // ⚠️ ONE plain `.gesture`, and deliberately NOT `.simultaneousGesture`. Simultaneous
            // means "recognise alongside whatever else does", so a drag that started on a line
            // moved the line AND panned the picture under it (Tomas, 2026-08-15). As a plain
            // container gesture it yields to the lines' own high-priority drags, and only picks up
            // touches that miss every grab zone.
            .gesture(magnify.simultaneously(with: panGesture(shown: shown)))
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomOrigin ?? zoom
                if zoomOrigin == nil { zoomOrigin = start }
                zoom = min(max(start * value.magnification, Self.zoomRange.lowerBound),
                           Self.zoomRange.upperBound)
            }
            .onEnded { _ in zoomOrigin = nil; if zoom == 1 { pan = .zero } }
    }

    /// Pans only while zoomed in — at 1× there is nothing off screen, and a stray pan there would
    /// just slide the card out from under the lines.
    private func panGesture(shown: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                let start = panOrigin ?? pan
                if panOrigin == nil { panOrigin = start }
                // Clamped to the overhang, so the picture can't be flung off screen.
                let maxX = shown.width * (zoom - 1) / 2, maxY = shown.height * (zoom - 1) / 2
                pan = CGSize(
                    width: min(max(start.width + value.translation.width, -maxX), maxX),
                    height: min(max(start.height + value.translation.height, -maxY), maxY))
            }
            .onEnded { _ in panOrigin = nil }
    }

    /// Seeds once. In `onAppear` rather than `init` because the fallback needs the plate's real
    /// pixel size, and re-seeding on a later appearance would silently discard a drag.
    private func seed() {
        guard !seeded else { return }
        seeded = true
        if let saved = initial {
            inset[.outerLeft] = CGFloat(saved.outerLeft)
            inset[.innerLeft] = CGFloat(saved.innerLeft)
            inset[.outerRight] = CGFloat(saved.outerRight)
            inset[.innerRight] = CGFloat(saved.innerRight)
            inset[.outerTop] = CGFloat(saved.outerTop)
            inset[.innerTop] = CGFloat(saved.innerTop)
            inset[.outerBottom] = CGFloat(saved.outerBottom)
            inset[.innerBottom] = CGFloat(saved.innerBottom)
            return
        }
        // The crop is a known factor wider than the detected card, so the card's edge is expected
        // at this inset. It is a starting position, not a claim — the user drags it onto the
        // actual edge, which is exactly the correction the detector cannot make for itself.
        let hMargin = plateSize.width * (EditorPlate.margin - 1) / (2 * EditorPlate.margin)
        let vMargin = plateSize.height * (EditorPlate.margin - 1) / (2 * EditorPlate.margin)
        let detected = plate.cgImage.flatMap(CenteringMeter.measure(cgImage:))
        inset[.outerLeft] = hMargin
        inset[.outerRight] = hMargin
        inset[.outerTop] = vMargin
        inset[.outerBottom] = vMargin
        inset[.innerLeft] = hMargin + CGFloat(detected?.left ?? 0)
        inset[.innerRight] = hMargin + CGFloat(detected?.right ?? 0)
        inset[.innerTop] = vMargin + CGFloat(detected?.top ?? 0)
        inset[.innerBottom] = vMargin + CGFloat(detected?.bottom ?? 0)
        // With no detection there is nothing to say about the border, so put the inner lines a
        // visible distance inside the card rather than on top of the outer ones.
        if detected == nil {
            inset[.innerLeft] = hMargin + plateSize.width * 0.05
            inset[.innerRight] = hMargin + plateSize.width * 0.05
            inset[.innerTop] = vMargin + plateSize.height * 0.05
            inset[.innerBottom] = vMargin + plateSize.height * 0.05
        }
    }

    /// One draggable line, with a grab handle. The rule stays hairline so it can be placed against
    /// a real edge precisely; the handle is what the finger goes for, and it carries the colour and
    /// the side so a line is identifiable while a hand covers most of the picture.
    @ViewBuilder
    private func lineView(_ line: Line, in shown: CGSize, scale: CGFloat) -> some View {
        let vertical = line.isVertical
        let isActive = active == line
        // Right and bottom lines are inset from the far edge, so a drag toward that edge decreases
        // their inset — the delta has to be negated for those.
        let sign: CGFloat = (line.alignment == .trailing || line.alignment == .bottom) ? -1 : 1
        // Divided by `zoom` because the whole stack is scaled: the offset is applied in unzoomed
        // points, while `scale` already includes the zoom.
        let offset = px(line) * scale / zoom
        let color = line.isOuter ? Self.outerColor : Self.innerColor

        ZStack {
            // Purely visual, and explicitly not hit-testable: a 1pt rule is not a touch target,
            // and leaving it hittable only creates a sliver that behaves differently from the
            // band beside it.
            Rectangle()
                .fill(color)
                .frame(width: vertical ? (isActive ? 2 : 1) / zoom : shown.width,
                       height: vertical ? shown.height : (isActive ? 2 : 1) / zoom)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .opacity(isActive ? 1 : 0.75)
                .allowsHitTesting(false)
            grabZone(line, color: color, isActive: isActive, in: shown,
                     vertical: vertical, scale: scale)
        }
        .frame(width: shown.width, height: shown.height, alignment: line.alignment)
        .offset(x: vertical ? sign * offset : 0, y: vertical ? 0 : sign * offset)
        .accessibilityElement()
        .accessibilityLabel(line.label)
        .accessibilityValue("\(Int(px(line).rounded())) pixels from the edge")
        // Dragging is unreachable with VoiceOver, so the same adjustment has to exist as an
        // increment/decrement — this is the only way the feature works at all for those users.
        .accessibilityAdjustableAction { direction in
            active = line
            inset[line] = clamp(px(line) + (direction == .increment ? 1 : -1), line)
        }
    }

    /// The line's touch target: one knob, at the MIDDLE of the edge, offset perpendicular to the
    /// line — outward for a card edge, inward for a border.
    ///
    /// ⚠️ Both knobs of a pair sit at the same point ALONG the edge, and that is a measurement
    /// decision, not a layout one. The card's edge is slightly curved in the picture (phone lens
    /// barrel distortion, which a homography cannot undo — it maps straight lines to straight
    /// lines by definition), so a straight line can match the middle of an edge or its ends, never
    /// both. The distortion is near-identical for two lines a few pixels apart at the same point,
    /// so it cancels out of the border width — but only if the pair is aligned at the same place.
    /// Handles previously sat at 30% and 70% along the line, which invited exactly the opposite
    /// (Tomas, screenshots, 2026-08-15).
    ///
    /// Separating the pair perpendicular instead keeps two 44pt targets ~52pt apart no matter how
    /// thin the border is — along-the-line separation could not do that, since a hairline border
    /// puts the two lines within a few points of each other.
    ///
    /// Sizes are divided by `zoom` because the whole stack is scaled: this keeps the knob at a
    /// constant size ON SCREEN, so zooming in to place a line precisely never shrinks the thing
    /// you place it with.
    @ViewBuilder
    private func grabZone(_ line: Line, color: Color, isActive: Bool,
                          in shown: CGSize, vertical: Bool, scale: CGFloat) -> some View {
        let sign: CGFloat = (line.alignment == .trailing || line.alignment == .bottom) ? -1 : 1
        // Which way is "out of the card" for this edge, then outward for the card edge and inward
        // for the border, so the two never stack.
        let outward: CGFloat = (line.alignment == .leading || line.alignment == .top) ? -1 : 1
        let perpendicular = outward * (line.isOuter ? 1 : -1) * 26 / zoom

        ZStack {
            Circle().fill(color)
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5 / zoom)
            Image(systemName: vertical ? "arrow.left.and.right" : "arrow.up.and.down")
                .font(.system(size: 9 / zoom, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 24 / zoom, height: 24 / zoom)
        .scaleEffect(isActive ? 1.3 : 1)
        .shadow(color: .black.opacity(0.5), radius: 2 / zoom)
        .animation(.easeOut(duration: 0.12), value: isActive)
        // A 48pt target that stays 48pt on screen at every zoom level.
        .frame(width: 48 / zoom, height: 48 / zoom)
        .contentShape(Circle())
        .offset(x: vertical ? perpendicular : 0, y: vertical ? 0 : perpendicular)
        // `translation` is cumulative from where the gesture began, so it must be applied to the
        // value AT THAT MOMENT, not to the running value — adding it every frame compounds and the
        // line races away from the finger. One shared origin is enough: only one line can be under
        // a finger at a time.
        //
        // `highPriorityGesture`, so a touch that lands on this knob beats the container's
        // pinch/pan outright instead of racing it.
        .highPriorityGesture(
            DragGesture()
                .onChanged { g in
                    let base = dragOrigin ?? px(line)
                    if dragOrigin == nil { dragOrigin = base }
                    active = line
                    let delta = vertical ? g.translation.width : g.translation.height
                    inset[line] = clamp(base + sign * delta / scale, line)
                }
                .onEnded { _ in dragOrigin = nil }
        )
        // Mid-edge: the same point along the line for both members of a pair, so the lens bow
        // affects them equally and cancels out of the width between them.
        .position(x: vertical ? 0 : shown.width / 2,
                  y: vertical ? shown.height / 2 : 0)
        .frame(width: vertical ? 0 : shown.width, height: vertical ? shown.height : 0)
    }

    /// Keeps a line on the picture, and keeps each side's pair in order: an inner line may not
    /// cross its own outer line, which would otherwise save a negative border width.
    private func clamp(_ v: CGFloat, _ line: Line) -> CGFloat {
        let limit = (line.isVertical ? plateSize.width : plateSize.height) / 2 - 1
        switch line {
        case .outerLeft: return min(max(v, 0), px(.innerLeft))
        case .outerRight: return min(max(v, 0), px(.innerRight))
        case .outerTop: return min(max(v, 0), px(.innerTop))
        case .outerBottom: return min(max(v, 0), px(.innerBottom))
        case .innerLeft: return min(max(v, px(.outerLeft)), limit)
        case .innerRight: return min(max(v, px(.outerRight)), limit)
        case .innerTop: return min(max(v, px(.outerTop)), limit)
        case .innerBottom: return min(max(v, px(.outerBottom)), limit)
        }
    }
}
