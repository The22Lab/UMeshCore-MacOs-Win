import SwiftUI
import QuartzCore

struct TimelineContainerView<Content: View>: View {
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let safeMargin: CGFloat
    @Binding private var height: CGFloat
    private let content: Content

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat?
    @State private var lastResizeTick: CFTimeInterval = 0

    init(
        height: Binding<CGFloat>,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        safeMargin: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self._height = height
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.safeMargin = safeMargin
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            content
                .frame(height: height)
        }
    }

    private var dragHandle: some View {
        ZStack {
            Color.clear
                .frame(height: 7)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            UM.textPrimary.opacity(isDragging ? 0.72 : (isHovering ? 0.52 : 0.30)),
                            UM.textPrimary.opacity(isDragging ? 0.58 : (isHovering ? 0.40 : 0.22))
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 46, height: 4)
                .opacity(isDragging ? 1.0 : (isHovering ? 0.9 : 0.6))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
            #if os(macOS)
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
            #endif
        }
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartHeight == nil {
                    dragStartHeight = height
                    isDragging = true
                    lastResizeTick = CACurrentMediaTime()
                }
                let baseHeight = dragStartHeight ?? height
                let proposed = baseHeight - value.translation.height
                let clamped = clampedHeight(for: proposed)
                let rounded = (clamped * 2).rounded() / 2
                let now = CACurrentMediaTime()

                // Coalesce updates to display cadence to reduce layout stutter
                // when heavy timeline content is being recomputed.
                if now - lastResizeTick < (1.0 / 120.0), abs(rounded - height) < 1.0 {
                    return
                }
                lastResizeTick = now

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    height = rounded
                }
            }
            .onEnded { value in
                let baseHeight = dragStartHeight ?? height
                let proposed = baseHeight - value.translation.height
                let clamped = clampedHeight(for: proposed)
                dragStartHeight = nil
                withAnimation(.easeOut(duration: 0.10)) {
                    height = clamped
                    isDragging = false
                }
            }
    }

    private func clampedHeight(for value: CGFloat) -> CGFloat {
        clamp(value, min: minHeight, max: maxHeight - safeMargin)
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}
