import SwiftUI

struct CapsuleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?

    @State private var isDragging = false
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartValue: Double = 0

    private let trackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 20

    /// Fires with `true` when a drag begins and `false` when it ends, so callers
    /// can bracket the whole gesture in a single undo step instead of recording
    /// one per intermediate value. Defaults to a no-op, so existing call sites
    /// keep working unchanged.
    private let onEditingChanged: (Bool) -> Void

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = fraction * (trackW - thumbDiameter)
            let fillW = max(thumbX + thumbDiameter * 0.5, trackHeight)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UM.textPrimary.opacity(0.085))
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity)

                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.43, green: 0.21, blue: 0.92),
                                 Color(red: 0.63, green: 0.47, blue: 1.0)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: fillW, height: trackHeight)

                ZStack {
                    Text(badgeText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(red: 0.43, green: 0.21, blue: 0.92)))
                        .fixedSize()
                        .offset(y: -(thumbDiameter + 10))
                        .opacity(isDragging ? 1 : 0)
                        .scaleEffect(isDragging ? 1 : 0.6, anchor: .bottom)
                        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)

                    ZStack {
                        // Active: dark fill + neon glow ring
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.55, green: 0.15, blue: 1.0).opacity(0.25))
                                .frame(width: 38, height: 38)
                                .blur(radius: 8)
                            Circle()
                                .strokeBorder(Color(red: 0.72, green: 0.28, blue: 1.0), lineWidth: 2.5)
                                .frame(width: thumbDiameter + 6, height: thumbDiameter + 6)
                                .shadow(color: Color(red: 0.72, green: 0.28, blue: 1.0).opacity(0.9), radius: 8)
                                .shadow(color: Color(red: 0.55, green: 0.15, blue: 1.0).opacity(0.5), radius: 14)
                            Circle()
                                .fill(Color(red: 0.08, green: 0.02, blue: 0.20))
                                .frame(width: thumbDiameter, height: thumbDiameter)
                        }
                        .opacity(isDragging ? 1 : 0)
                        .scaleEffect(isDragging ? 1.0 : 0.7)
                        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isDragging)

                        // Idle: white with double ring
                        ZStack {
                            Circle()
                                .fill(Color.white)
                            Circle()
                                .strokeBorder(Color(white: 0.68), lineWidth: 1.5)
                            Circle()
                                .strokeBorder(Color(white: 0.82), lineWidth: 1.0)
                                .padding(3)
                        }
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
                        .opacity(isDragging ? 0 : 1)
                        .scaleEffect(isDragging ? 0.7 : 1.0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isDragging)
                    }
                    .frame(width: thumbDiameter, height: thumbDiameter)
                }
                .offset(x: thumbX)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            dragStartX = drag.startLocation.x
                            dragStartValue = value
                            onEditingChanged(true)
                        }
                        let delta = drag.location.x - dragStartX
                        let startFraction = (dragStartValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                        let newFraction = max(0, min(1, startFraction + delta / max(trackW - thumbDiameter, 1)))
                        var newValue = range.lowerBound + newFraction * (range.upperBound - range.lowerBound)
                        if let step {
                            newValue = (newValue / step).rounded() * step
                            newValue = max(range.lowerBound, min(range.upperBound, newValue))
                        }
                        value = newValue
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: thumbDiameter)
    }

    private var badgeText: String {
        if let step, step >= 1 {
            return "\(Int(value.rounded()))"
        } else if range.upperBound - range.lowerBound <= 1.5 {
            return String(format: "%.2f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }
}
