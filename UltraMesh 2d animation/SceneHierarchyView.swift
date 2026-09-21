import SwiftUI

/// Everything in a Scene, in one tree.
///
/// The Editor's hierarchy shows a rig's images, bones and meshes; this shows a
/// scene's cards and its lights. Same shape, same section headers with their
/// counts, same selection highlight, same glyph-before-name — adapted, because
/// the two are showing different things and a scene has no bones.
///
/// ## Why the cards are listed front-most first
///
/// Because the Editor's hierarchy is, and because `DrawOrderView` says so in as
/// many words: "top row = front-most layer". Scene's list used to be the array
/// reversed, which came to the same thing while the array WAS the draw order.
/// It is not any more — `SceneLayer.sortingOrder` is — so the list is built
/// from `frontToBackLayers` and the two cannot drift.
///
/// ## Why lights are a section and not layers
///
/// A light draws no pixels, so it has no place in a stacking order. Giving it a
/// layer number would be a control that changes nothing, and an artist would
/// reasonably spend an afternoon on why their light will not come forward.
struct SceneHierarchyView: View {
    @EnvironmentObject private var appState: AppState
    let composition: SceneComposition

    private var sceneManager: SceneManager { appState.sceneManager }
    private var assetManager: AssetManager { appState.assetManager }

    @State private var expanded: Set<String> = ["cards", "lights"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section("cards", title: "Cards", icon: "square.stack.3d.up",
                            count: composition.layers.count)
                    if expanded.contains("cards") {
                        ForEach(composition.frontToBackLayers) { layer in
                            cardRow(layer)
                        }
                        if composition.layers.isEmpty { emptyNote("No cards on the set.") }
                    }

                    section("lights", title: "Lighting", icon: "lightbulb",
                            count: composition.lights.count)
                    if expanded.contains("lights") {
                        ForEach(composition.lights) { light in
                            lightRow(light)
                        }
                        if composition.lights.isEmpty {
                            emptyNote("No lights. The scene renders at full ambient.")
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(UM.surface)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 6) {
            Text("Scene")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(UM.textPrimary)
            Spacer(minLength: 0)
            addMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func section(_ key: String, title: String, icon: String, count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded.contains(key) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(UM.textMuted)
                    .frame(width: 10)
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(UM.textMuted)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(UM.textMuted)
                    .tracking(0.7)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(UM.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(UM.textPrimary.opacity(0.07)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, key == "cards" ? 2 : 8)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(UM.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)
            .padding(.vertical, 4)
    }

    // MARK: - Rows

    @ViewBuilder
    private func cardRow(_ layer: SceneLayer) -> some View {
        let isSelected = sceneManager.sceneSelection == .layer(layer.id)
        HStack(spacing: 7) {
            visibilityButton(isHidden: layer.isHidden) {
                sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                    $0.isHidden.toggle()
                }
            }
            Image(systemName: Self.icon(layer.content))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UM.accentStrong)
                .frame(width: 14)
            Text(layer.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(layer.isHidden ? UM.textMuted : UM.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            // THE LAYER NUMBER, not the depth. Z was shown here while the array
            // was the draw order, which put the one number that does NOT decide
            // stacking in the column an artist reads for stacking.
            Text("L\(layer.sortingOrder)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(UM.textMuted)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(UM.textPrimary.opacity(0.07)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected))
        .contentShape(Rectangle())
        .onTapGesture { sceneManager.selectSceneLayer(layer.id) }
        .contextMenu {
            Button("Bring Forward") {
                sceneManager.moveSceneLayer(layer.id, in: composition.id, forward: true)
            }
            Button("Send Backward") {
                sceneManager.moveSceneLayer(layer.id, in: composition.id, forward: false)
            }
            Divider()
            Button("Delete", role: .destructive) {
                sceneManager.removeSceneLayer(layer.id, from: composition.id)
                if sceneManager.sceneSelection == .layer(layer.id) {
                    sceneManager.selectSceneLayer(nil)
                }
            }
        }
    }

    @ViewBuilder
    private func lightRow(_ light: SceneLight) -> some View {
        let isSelected = sceneManager.sceneSelection == .light(light.id)
        HStack(spacing: 7) {
            // The enable toggle wears the light's own colour, which is how two
            // lights are told apart in a list without reading their names.
            Button {
                sceneManager.updateSceneLight(light.id, in: composition.id) {
                    $0.isEnabled.toggle()
                }
            } label: {
                Image(systemName: light.isEnabled ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(light.isEnabled
                                     ? Color(red: Double(light.color.x),
                                             green: Double(light.color.y),
                                             blue: Double(light.color.z))
                                     : UM.textMuted)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            Image(systemName: light.kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UM.accentStrong)
                .frame(width: 14)
            Text(light.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(light.isEnabled ? UM.textPrimary : UM.textMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(light.mask.channelNumbers.map(String.init).joined(separator: ","))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(UM.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected))
        .contentShape(Rectangle())
        .onTapGesture { sceneManager.selectSceneLight(light.id) }
        .contextMenu {
            Button("Move Up") {
                sceneManager.moveSceneLight(light.id, in: composition.id, forward: false)
            }
            Button("Move Down") {
                sceneManager.moveSceneLight(light.id, in: composition.id, forward: true)
            }
            Divider()
            Button("Delete", role: .destructive) {
                sceneManager.removeSceneLight(light.id, from: composition.id)
            }
        }
    }

    private func visibilityButton(isHidden: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isHidden ? "eye.slash" : "eye")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(UM.textMuted)
                .frame(width: 14)
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? UM.accent.opacity(0.30) : .clear)
            .padding(.horizontal, 4)
    }

    static func icon(_ content: SceneLayerContent) -> String {
        switch content {
        case .rig:   return "figure.walk"
        case .plate: return "photo"
        case .fill:  return "square.fill"
        }
    }

    // MARK: - Adding

    private var addMenu: some View {
        Menu {
            Button("Rig Instance") { add(.rig(clipID: UUID(), speed: 1, startFrame: 0, loops: true)) }
            Divider()
            Button("Import PNG…") { appState.importScenePlate() }
            // PLACEABLE ONLY. A normal map is not artwork and cannot be a
            // plate: it has no atlas entry, so a card built from one has no
            // UV rect to sample through.
            ForEach(assetManager.placeableAssets) { asset in
                Button("Plate — \(asset.name)") { add(.plate(assetID: asset.id)) }
            }
            Divider()
            Button("Fill") { add(.fill(.neutral)) }
            Divider()
            ForEach(SceneLightKind.allCases) { kind in
                Button("\(kind.title) Light") {
                    sceneManager.addSceneLight(kind: kind, to: composition.id)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(UM.textPrimary.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(UM.accentSoft))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func add(_ content: SceneLayerContent) {
        let name: String
        switch content {
        case .rig:   name = "Rig \(composition.layers.count + 1)"
        case let .plate(assetID):
            name = assetManager.asset(for: assetID)?.name ?? "Plate"
        case .fill:  name = "Fill"
        }
        // On a NEW LAYER in front of everything, at the camera's focal depth. A
        // card landing behind the set is a card the artist cannot see and
        // reports as not having been created.
        let layer = SceneLayer(
            name: name,
            positionZ: sceneManager.defaultLayerZ(in: composition),
            sortingOrder: composition.frontSortingOrder,
            content: content
        )
        sceneManager.addSceneLayer(layer, to: composition.id)
        sceneManager.selectSceneLayer(layer.id)
    }
}
