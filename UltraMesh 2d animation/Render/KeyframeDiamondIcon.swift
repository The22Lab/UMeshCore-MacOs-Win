import SwiftUI

/// The key button's face: the diamond it puts on the timeline.
///
/// It used to be an SF key glyph, which is not what a press produces. A press
/// makes a diamond appear on a track, so the button is that diamond, in the
/// colour of the channel the press would write.
///
/// The press animation is meant to feel physical rather than decorative: a
/// quick squash to acknowledge the touch, one overshoot on the way back, and a
/// settle at rest — plus a ring that expands and fades to nothing. "Premium"
/// here means fast and definite; anything that lingers reads as lag.
struct KeyframeDiamondIcon: View {

    /// One leg of the press. Read out of here by the verification harness, so
    /// the shipped numbers and the checked numbers cannot come apart.
    struct PressStage {
        let scale: CGFloat
        let duration: TimeInterval
    }

    /// Squash, overshoot, settle. Ends at 1.0 so nothing is left mid-flight,
    /// and the squash is the shortest leg so the press feels immediate.
    static let pressStages: [PressStage] = [
        PressStage(scale: 0.74, duration: 0.07),
        PressStage(scale: 1.22, duration: 0.15),
        PressStage(scale: 1.0, duration: 0.20)
    ]

    /// ringScale: 0.55 ... 2.30 — outward.
    /// ringOpacity: 0.55 ... 0.0 — and gone, no residue on the button.
    static let ringScaleRange: ClosedRange<CGFloat> = 0.55...2.30
    static let ringOpacityRange: ClosedRange<Double> = 0.0...0.55

    enum Fill {
        /// Nothing keyed here: an outline, like an empty frame.
        case hollow
        /// Some channels keyed, not all: a core inside the outline.
        case core
        /// The whole thing is keyed: solid.
        case solid
    }

    let color: Color
    let fill: Fill
    let isEnabled: Bool
    /// Bumped by the owner on every accepted press; drives the animation.
    let pressCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { isEnabled ? color : color.opacity(0.32) }

    var body: some View {
        ZStack {
            ring
            diamond
        }
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: 0.18), value: fill)
    }

    private var diamond: some View {
        DiamondShape()
            .fill(fill == .solid ? tint : tint.opacity(0.14))
            .overlay(
                DiamondShape()
                    .stroke(tint, lineWidth: fill == .solid ? 0 : 1.6)
            )
            .overlay(
                DiamondShape()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(fill == .core ? 1 : 0)
            )
            .frame(width: 13, height: 13)
            .modifier(PressSquash(pressCount: pressCount, enabled: !reduceMotion))
            .shadow(color: tint.opacity(fill == .solid ? 0.45 : 0.0), radius: 4)
    }

    private var ring: some View {
        DiamondShape()
            .stroke(tint, lineWidth: 1.4)
            .frame(width: 13, height: 13)
            .modifier(PressRing(pressCount: pressCount, enabled: !reduceMotion))
    }
}

/// The diamond itself — the same square-on-its-corner the timeline draws.
struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// Squash, overshoot, settle, driven off a counter so repeated presses restart
/// cleanly rather than queueing.
private struct PressSquash: ViewModifier, Animatable {
    let pressCount: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(
                initialValue: CGFloat(1.0),
                trigger: pressCount
            ) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    for stage in KeyframeDiamondIcon.pressStages {
                        SpringKeyframe(stage.scale, duration: stage.duration)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// The expanding ring. It starts at the diamond's own size so it reads as
/// coming OUT of it, and ends invisible.
private struct PressRing: ViewModifier {
    let pressCount: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(
                initialValue: RingState(scale: KeyframeDiamondIcon.ringScaleRange.lowerBound,
                                        opacity: 0),
                trigger: pressCount
            ) { view, state in
                view
                    .scaleEffect(state.scale)
                    .opacity(state.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(KeyframeDiamondIcon.ringScaleRange.lowerBound, duration: 0.0)
                    SpringKeyframe(KeyframeDiamondIcon.ringScaleRange.upperBound, duration: 0.42)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(KeyframeDiamondIcon.ringOpacityRange.upperBound, duration: 0.06)
                    LinearKeyframe(KeyframeDiamondIcon.ringOpacityRange.lowerBound, duration: 0.36)
                }
            }
        } else {
            content.opacity(0)
        }
    }
}

private struct RingState: Animatable {
    var scale: CGFloat
    var opacity: Double

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(scale, opacity) }
        set {
            scale = newValue.first
            opacity = newValue.second
        }
    }
}
