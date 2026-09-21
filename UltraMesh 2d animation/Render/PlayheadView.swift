import SwiftUI

/// The timeline's playhead: a head you can take hold of, and a line under it.
///
/// The old one was a bare 2pt rectangle with no handle — scrubbing worked on
/// the 40pt ruler strip and nowhere else, and there was nothing to grab. After
/// Effects gives you a head, and both tell you the frame while
/// you drag it; this does the same.
///
/// It is also the only thing that observes `PlayheadClock`, which is the point:
/// a playback tick redraws this line and nothing else.
struct PlayheadView: View {

    /// Wide enough for a fingertip, around a line that is a point and a half.
    /// Aiming at the line itself is not a control, it is a test of nerve.
    static let grabWidth: CGFloat = 34

    private static let lineWidth: CGFloat = 1.5
    private static let headHeight: CGFloat = 40

    @ObservedObject var clock: PlayheadClock

    /// Viewport x of a fractional frame, already scrolled.
    let xForFrame: (Double) -> CGFloat
    /// Left edge of the scrubbable area — the frozen names column ends here, so
    /// the head slides under it rather than over it.
    let leftEdge: CGFloat
    let bodyHeight: CGFloat
    let isScrubbing: Bool
    let label: (Double) -> String
    /// Points dragged, from where the drag began.
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var dragOrigin: CGFloat?

    private var tint: Color { UM.animatorAccent }

    var body: some View {
        let x = xForFrame(clock.frame)

        ZStack(alignment: .topLeading) {
            // The line: crisp, one and a half points, and brighter while you
            // are moving it.
            Rectangle()
                .fill(tint.opacity(isScrubbing ? 1.0 : 0.85))
                .frame(width: Self.lineWidth, height: bodyHeight)
                .offset(x: x - Self.lineWidth / 2, y: Self.headHeight)
                // ONLY WHILE SCRUBBING. It was applied unconditionally at zero
                // opacity — an invisible shadow still costs a rasterisation
                // pass, and this view is rebuilt at display rate.
                .shadow(color: isScrubbing ? tint.opacity(0.45) : .clear,
                        radius: isScrubbing ? 4 : 0)

            head
                .offset(x: x, y: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(
            Rectangle()
                .offset(x: leftEdge)
        )
        .allowsHitTesting(true)
    }

    private var head: some View {
        // The head is its OWN view, and that is the point rather than tidiness.
        //
        // `PlayheadView` is invalidated on every tick of the clock, 120 times a
        // second on a ProMotion display — that is what makes the line move. All
        // of this was inside that body, so every one of those ticks formatted a
        // String, built a new `Text` (which forces text layout and
        // measurement), measured the head twice, and re-evaluated two rounded
        // rectangles with a shadow each. Shadows rasterise.
        //
        // The value it displays changes at most once per CLIP frame — thirty
        // times a second, not a hundred and twenty — so three quarters of that
        // work produced an identical picture. It is the playhead's own
        // rendering that was missing frames while the Metal canvas beside it
        // did not, which is what "la playhead se mira poco fluida" looks like.
        //
        // Extracted, its stored properties are a String and two Bools: SwiftUI
        // compares them, finds them unchanged, and skips the body. What is left
        // per tick is the `.offset` below, which is a render-tree change and
        // not a layout.
        PlayheadHead(text: label(clock.frame),
                     isScrubbing: isScrubbing,
                     tint: tint)
    }

}

/// The chip that rides the playhead, and the frame number in it.
///
/// A separate view so SwiftUI can skip it. Its inputs are a String and two
/// small values; when they have not changed — which is every tick between one
/// clip frame and the next — its body is not evaluated at all, and neither is
/// the text layout or the two shadows inside it.
private struct PlayheadHead: View {
    let text: String
    let isScrubbing: Bool
    let tint: Color

    private static let lineWidth: CGFloat = 1.5
    private static let headHeight: CGFloat = 40
    private static let grabWidth: CGFloat = 34

    /// Measured ONCE. It was computed twice per evaluation — for the frame and
    /// for the offset that centres it — which is cheap and was being paid at
    /// display rate for no reason.
    private var width: CGFloat { max(26, CGFloat(text.count) * 6.5 + 12) }

    var body: some View {
        let width = self.width
        return ZStack {
            // UltraMesh's own chip: a soft rounded rectangle with a hairline,
            // the same shape the transport and the filter chips use. The first
            // version of this was an After Effects pennant, which is a
            // different program's handwriting.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: tint.opacity(isScrubbing ? 0.45 : 0.20),
                        radius: isScrubbing ? 6 : 2, y: 1)

            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(UM.textOnAccent)
        }
        .frame(width: width, height: 17)
        .overlay(alignment: .bottom) {
            // A small stem down to the line, so which frame it marks is exact
            // without a pennant's bulk.
            Rectangle()
                .fill(tint)
                .frame(width: Self.lineWidth, height: 6)
                .offset(y: 6)
        }
        .offset(x: -width / 2, y: 8)
        .scaleEffect(isScrubbing ? 1.05 : 1.0, anchor: .center)
        .animation(.spring(response: 0.24, dampingFraction: 0.75), value: isScrubbing)
        // The grab area is invisible and much wider than the head, so a near
        // miss still takes hold of it.
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: Self.grabWidth, height: Self.headHeight)
        )
    }
}
