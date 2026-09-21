import SwiftUI

/// Display modes for the left panel: the structural tree, or a flat
/// draw-order list (Layer Order Mode).
enum HierarchyListMode: String, CaseIterable {
    case tree
    case drawOrder
    case skins
    case events

    var title: String {
        switch self {
        case .tree:      return "Tree"
        case .drawOrder: return "Draw Order"
        case .skins:     return "Skins"
        case .events:    return "Events"
        }
    }

    var icon: String {
        switch self {
        case .tree:      return "list.bullet.indent"
        case .drawOrder: return "square.3.layers.3d.down.right"
        case .skins:     return "tshirt"
        case .events:    return "bolt"
        }
    }
}

struct HierarchyPanelView: View {
    let assetManager: AssetManager
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var animationLibrary: AnimationLibrary
    let camera: CameraState

    @State private var listMode: HierarchyListMode = .tree

    private let boneAccent  = Color(red: 0.62, green: 0.50, blue: 0.85)

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Compact header: title + stat badges
                HStack(alignment: .center, spacing: 6) {
                    Text("Hierarchy")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(UM.textPrimary)
                    Spacer()
                    boneStatBadge(label: "\(boneCount)", color: boneAccent)
                    imageStatBadge(label: "\(imageCount)")
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 7)

                Rectangle()
                    .fill(UM.textPrimary.opacity(0.08))
                    .frame(height: 0.5)

                modeToggle
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                Rectangle()
                    .fill(UM.textPrimary.opacity(0.06))
                    .frame(height: 0.5)

                Group {
                    switch listMode {
                    case .tree:
                        HierarchyView(sceneManager: sceneManager, onFrameItem: frameItem)
                    case .drawOrder:
                        DrawOrderView(
                            sceneManager: sceneManager,
                            onFrameItem: frameItem
                        )
                    case .skins:
                        SkinsPanelView(sceneManager: sceneManager)
                    case .events:
                        EventsPanelView(sceneManager: sceneManager)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle()
                    .fill(UM.textPrimary.opacity(0.08))
                    .frame(height: 0.5)

                AnimationsPanelView(library: animationLibrary)
                    .padding(.bottom, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(UM.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(UM.textPrimary.opacity(0.09), lineWidth: 1)
                    )
            )
            .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UM.appBackground)
    }

    /// Compact segmented switch between the structural tree and Layer
    /// Order Mode, styled to match the panel chrome.
    private var modeToggle: some View {
        HStack(spacing: 3) {
            ForEach(HierarchyListMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        listMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(mode.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(listMode == mode ? UM.textPrimary : UM.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(listMode == mode ? UM.surfaceRaised : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(UM.surfaceInset))
    }

    /// Same badge, with the picture mark in place of a system glyph.
    @ViewBuilder
    private func imageStatBadge(label: String) -> some View {
        HStack(spacing: 3) {
            ImageGlyph()
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(UM.textPrimary.opacity(0.55))
        }
    }

    /// Same badge, with the bone silhouette in place of a system glyph.
    @ViewBuilder
    private func boneStatBadge(label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            BoneGlyph()
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(UM.textPrimary.opacity(0.55))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(UM.textPrimary.opacity(0.06)))
    }

    @ViewBuilder
    private func statBadge(label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(UM.textPrimary.opacity(0.55))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(UM.textPrimary.opacity(0.06)))
    }

    private func frameItem(id: UUID) {
        if let image = sceneManager.image(for: id),
           let asset = assetManager.asset(for: image.assetID) {
            let bounds = ToolUtilities.boundsForImage(image, asset: asset)
            camera.frame(bounds: bounds, padding: 60, duration: 0.25)
            return
        }
        if let segment = sceneManager.skeleton.lineSegment(for: id) {
            var bounds = Bounds2D.empty()
            bounds.include(segment.start)
            bounds.include(segment.end)
            camera.frame(bounds: bounds, padding: 60, duration: 0.25)
        }
    }

    private var imageCount: Int {
        sceneManager.hierarchyItems.filter { $0.type == .image }.count
    }

    private var boneCount: Int {
        sceneManager.skeleton.orderedBones.count
    }
}

#Preview {
    let scene = SceneManager()
    HierarchyPanelView(
        assetManager: AssetManager(device: MetalDeviceProvider.device),
        sceneManager: scene,
        animationLibrary: AnimationLibrary(scene: scene),
        camera: CameraState()
    )
}
