import SwiftUI

/// Properties of the selected layer, and of the shot.
///
/// Scene keyframes only the camera — layers are placed and stay put — so the
/// layer half is plain numeric fields with no key buttons, and only the camera
/// section will grow them.
struct SceneInspectorView: View {
    @EnvironmentObject private var appState: AppState

    let composition: SceneComposition

    private var sceneManager: SceneManager { appState.sceneManager }
    private var assetManager: AssetManager { appState.assetManager }
    /// True for the length of one slider drag.
    ///
    /// ONE @State FOR ALL THE SLIDERS, because only one can be dragged at a
    /// time and a flag each would be three ways to describe one gesture.
    @State private var draggingMaterial = false
    /// The one selection, read rather than passed: a copy handed down through
    /// three views is three chances to be looking at something else.
    private var selectedLayerID: UUID? { sceneManager.sceneSelection.layerID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let layer = selectedLayerID.flatMap({ composition.layer($0) }) {
                    layerSection(layer)
                } else if sceneManager.sceneSelection.lightID != nil {
                    // A light is selected, so the light section below is what
                    // the artist is looking at. Saying "select a layer" here
                    // would be the panel arguing with its own contents.
                    Text("A light is selected.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UM.textMuted)
                } else {
                    Text("Select a layer to place it.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UM.textMuted)
                }

                Divider().overlay(UM.textPrimary.opacity(0.08))

                cameraSection

                Divider().overlay(UM.textPrimary.opacity(0.08))

                SceneLightInspector(composition: composition)
            }
            .padding(12)
        }
        .background(UM.appBackground)
    }

    // MARK: - Layer

    @ViewBuilder
    private func layerSection(_ layer: SceneLayer) -> some View {
        title(layer.name.uppercased())

        field("X", layer.position.x) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) { $0.position.x = value }
        }
        field("Y", layer.position.y) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) { $0.position.y = value }
        }
        // Depth. Higher is further away, the direction After Effects uses.
        field("Z", layer.positionZ) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) { $0.positionZ = value }
        }

        title("STACKING")
        // THE LAYER, and it is the only thing that decides who covers whom.
        // Rounded rather than truncated so that typing 2.7 means layer 3 —
        // truncation would make a value typed between two layers land on the
        // one below, which is the opposite of where the pointer was heading.
        field("Layer", Float(layer.sortingOrder)) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                $0.sortingOrder = Int(value.rounded())
            }
        }
        Text("Higher is nearer the front. Two cards on one layer keep the order "
             + "they were created in. Depth changes size and parallax, never "
             + "stacking.")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(UM.textMuted)
            .fixedSize(horizontal: false, vertical: true)

        field("Rotation X", degrees(layer.rotation3D.x)) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                $0.rotation3D.x = radians(value)
            }
        }
        field("Rotation Y", degrees(layer.rotation3D.y)) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                $0.rotation3D.y = radians(value)
            }
        }
        // Z rotation is the card spinning in its own plane, which the layer
        // already carries as `rotation` — so the three rows the artist asked
        // for are complete without a fourth value that would mean the same
        // thing twice.
        field("Rotation Z", degrees(layer.rotation)) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                $0.rotation = radians(value)
            }
        }

        field("Scale X", layer.scale.x) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) { $0.scale.x = value }
        }
        field("Scale Y", layer.scale.y) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) { $0.scale.y = value }
        }
        field("Opacity", layer.opacity) { value in
            sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                $0.opacity = min(max(value, 0), 1)
            }
        }

        title("LIGHTING")
        Toggle("Receives Light", isOn: Binding(
            get: { layer.receivesLight },
            set: { next in
                sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                    $0.receivesLight = next
                }
            }
        ))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(UM.textPrimary)
        if layer.receivesLight {
            // Indexed, not iterated over a Set: eight boxes in channel order on
            // every launch.
            HStack(spacing: 8) {
                Text("Channels")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UM.textSecondary)
                    .frame(width: 74, alignment: .leading)
                ForEach(SceneLightMask.channels.indices, id: \.self) { index in
                    let channel = SceneLightMask.channels[index]
                    let on = layer.lightMask.contains(channel)
                    Button {
                        sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                            var next = $0.lightMask
                            if on { next.remove(channel) } else { next.insert(channel) }
                            // A layer on no channel is unreachable by every
                            // light, which is what `Receives Light` is for —
                            // reaching it by emptying the mask instead would be
                            // two controls that mean the same thing, one of
                            // them invisible.
                            $0.lightMask = next.isEmpty ? channel : next
                        }
                    } label: {
                        Text("\(index + 1)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .frame(width: 16, height: 16)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(on ? UM.accent.opacity(0.8) : UM.surfaceInset)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(on ? Color.white : UM.textMuted)
                }
                Spacer(minLength: 0)
            }
        }

        materialSection(layer)

        if case let .rig(clipID, speed, startFrame, loops) = layer.content {
            title("PLAYBACK")
            field("Speed", speed) { value in
                sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                    $0.content = .rig(clipID: clipID, speed: value,
                                      startFrame: startFrame, loops: loops)
                }
            }
            field("Start Frame", Float(startFrame)) { value in
                sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                    $0.content = .rig(clipID: clipID, speed: speed,
                                      startFrame: Int(value.rounded()), loops: loops)
                }
            }
            Toggle("Loop", isOn: Binding(
                get: { loops },
                set: { next in
                    sceneManager.updateSceneLayer(layer.id, in: composition.id) {
                        $0.content = .rig(clipID: clipID, speed: speed,
                                          startFrame: startFrame, loops: next)
                    }
                }
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(UM.textPrimary)
        }
    }

    // MARK: - Material

    /// The surface: its relief, and how the light falls across it.
    ///
    /// Shown for every layer, because smoothness and contrast describe how a
    /// card sits in a set and apply whatever is drawn on it. What differs by
    /// kind is everything that names a MAP: a plate is one PNG so its normal
    /// map and its height field are the layer's, and a rig is many PNGs, so a
    /// row here would be a control that quietly did the wrong thing -- one
    /// shared map lighting the face by the arm's bumps, or displacing it by
    /// the arm's relief. The normal map row below and the whole PARALLAX
    /// section are skipped for a rig for that one reason.
    @ViewBuilder
    private func materialSection(_ layer: SceneLayer) -> some View {
        title("MATERIAL")

        switch layer.content {
        case .rig:
            Text("A rig's normal maps are per sprite — set them in the Editor's "
                 + "sprite inspector. Smoothness and Contrast below apply to the "
                 + "whole instance.")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(UM.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        case .plate, .fill:
            normalMapRow(layer)
        }

        // STRENGTH ONLY WHEN THERE IS SOMETHING TO SCALE. A slider that cannot
        // change the picture is a slider an artist drags twice and then stops
        // trusting.
        if hasNormalMap(layer) {
            materialSlider("Relief", layer.material.normalStrength, range: 0...4,
                           format: .multiple) { value, live in
                update(layer, live: live) { $0.material.normalStrength = value }
            }
        }

        materialSlider("Smoothness", layer.material.smoothness, range: 0...1,
                       format: .percent) { value, live in
            update(layer, live: live) { $0.material.smoothness = value }
        }
        materialSlider("Contrast", layer.material.contrast, range: 0...4,
                       format: .multiple) { value, live in
            update(layer, live: live) { $0.material.contrast = value }
        }

        // TWO MASKS AND NOT ONE TOGGLE. Casting and catching are different
        // decisions about the same card: a backdrop catches every shadow and
        // casts none, a character casts onto the set and usually should not
        // shadow itself, and a foreground plate does neither. One switch would
        // force those three into one.
        //
        // Both empty by default, so a card added today behaves as every card
        // did before shadows existed.
        shadowMaskRow("Casts On", layer.material.shadowCastMask) { next in
            update(layer) { $0.material.shadowCastMask = next }
        }
        shadowMaskRow("Shadowed By", layer.material.shadowedMask) { next in
            update(layer) { $0.material.shadowedMask = next }
        }

        parallaxSection(layer)
    }

    // MARK: - Parallax

    /// The march that gives a flat PNG real depth.
    ///
    /// ## Why this is its own section and not three more rows of MATERIAL
    ///
    /// Everything above describes how a surface ANSWERS light. Parallax
    /// describes where the surface IS: it moves texels, it can throw them away,
    /// and it is the one control here that changes what the card covers. An
    /// artist reaching for "why is my brick wall flat" is looking for a heading,
    /// not for a fourth slider under a normal map picker.
    ///
    /// ## Per layer, and so only where a layer IS one PNG
    ///
    /// Same split the normal map already makes, and for a sharper reason: a
    /// plate is one image so its height field is the layer's, while a rig is
    /// many and one shared field would displace the face by the arm's relief.
    /// The renderer forces the mode off for a rig regardless; this just stops
    /// the panel offering a control that would quietly do nothing.
    @ViewBuilder
    private func parallaxSection(_ layer: SceneLayer) -> some View {
        if case .rig = layer.content {
            EmptyView()
        } else {
            title("PARALLAX")

            parallaxModeRow(layer)

            if layer.material.parallaxMode != .off {
                heightMapRow(layer)

                // NO HEIGHT FIELD, NO MARCH — and the panel says so rather
                // than showing five live sliders over a surface the renderer
                // is drawing flat. `materialFields` decides the same thing from
                // the texture, so this is the inspector agreeing with the
                // picture instead of describing a different one.
                if heightSource(layer) == nil {
                    Text("No height field. Import a file named …_h.png, or give "
                         + "the normal map an alpha channel.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(UM.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                materialSlider("Depth", layer.material.parallaxDepth,
                               range: 0...0.5, format: .percent) { value, live in
                    update(layer, live: live) { $0.material.parallaxDepth = value }
                }
                materialSlider("Quality", layer.material.parallaxQuality,
                               range: 0...1, format: .percent) { value, live in
                    update(layer, live: live) { $0.material.parallaxQuality = value }
                }
                materialSlider("Occlusion", layer.material.parallaxOcclusionStrength,
                               range: 0...1, format: .percent) { value, live in
                    update(layer, live: live) {
                        $0.material.parallaxOcclusionStrength = value
                    }
                }

                parallaxToggle("Invert Height", isOn: layer.material.heightInverted) { next in
                    update(layer) { $0.material.heightInverted = next }
                }
                parallaxToggle("Self-Shadow", isOn: layer.material.parallaxSelfShadow) { next in
                    update(layer) { $0.material.parallaxSelfShadow = next }
                }

                Text(parallaxHint(layer))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(UM.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func parallaxToggle(_ label: String, isOn: Bool,
                                set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: set))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(UM.textPrimary)
    }

    private func parallaxModeRow(_ layer: SceneLayer) -> some View {
        HStack(spacing: 8) {
            Text("Mode")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            Menu {
                ForEach(SceneParallaxMode.allCases) { mode in
                    Button(mode.title) {
                        update(layer) { $0.material.parallaxMode = mode }
                    }
                }
            } label: {
                menuLabel(layer.material.parallaxMode.title,
                          muted: layer.material.parallaxMode == .off)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    /// What the march will actually read, if anything.
    ///
    /// THREE ANSWERS AND NOT TWO, which is why this returns a description
    /// rather than a Bool. A layer can have its own height map, or fall back to
    /// the normal map's alpha, or have neither — and the row has to say which,
    /// because "no relief appeared" has a different fix in each case.
    private enum HeightSource {
        case map(String)
        case normalAlpha
        case missingFile
    }

    private func heightSource(_ layer: SceneLayer) -> HeightSource? {
        if let id = layer.material.heightMapAssetID {
            // A NAMED-BUT-MISSING MAP SAYS SO, the same as the normal map row:
            // falling back to the alpha here would tell the artist their pick
            // never took, and they would pick it again and watch nothing
            // happen, because the file is what moved.
            guard let asset = assetManager.asset(for: id) else { return .missingFile }
            return .map(asset.name)
        }
        // The fallback is only real when there is a normal map to read it from.
        guard let normalID = layer.material.normalMapAssetID,
              assetManager.asset(for: normalID) != nil else { return nil }
        return .normalAlpha
    }

    private func heightMapName(_ layer: SceneLayer) -> String {
        guard let source = heightSource(layer) else { return "None" }
        switch source {
        case let .map(name): return name
        case .normalAlpha:   return "From normal alpha"
        case .missingFile:   return "Missing file"
        }
    }

    /// One line saying what the chosen mode does to the outline.
    ///
    /// The three modes differ in exactly one respect and it is not visible in
    /// the menu: whether the card's rectangle is still the outline, and whether
    /// the relief may paint outside it.
    private func parallaxHint(_ layer: SceneLayer) -> String {
        switch layer.material.parallaxMode {
        case .off:
            return ""
        case .occlusion:
            return "The relief parallaxes against the card, but the card's "
                 + "rectangle is still the outline."
        case .silhouetteClip:
            return "The outline follows the relief, biting inwards. The card "
                 + "keeps its size."
        case .silhouetteShell:
            return "The card is drawn larger by Depth so the relief can stand "
                 + "proud of its edge. Selection, framing and shadows still use "
                 + "the card's real size."
        }
    }

    /// The pill every picker menu wears, so the three cannot drift apart.
    ///
    /// The swatch goes INSIDE the pill, not beside it: a map picker reads as
    /// one control, and a thumbnail floating outside the rounded rect looks
    /// like a separate button an artist will try to click.
    private func menuLabel(_ text: String, muted: Bool,
                           thumbnailID: UUID? = nil,
                           showsThumbnail: Bool = false) -> some View {
        HStack(spacing: 6) {
            if showsThumbnail { thumbnail(thumbnailID) }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(muted ? UM.textMuted : UM.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(UM.surfaceInset)
        )
    }

    /// The eight channels, as toggles. Unlike a light's mask this one MAY be
    /// emptied: empty means "casts nothing" and "catches nothing", which is the
    /// default and the commonest answer. A light's mask cannot be emptied
    /// because a light on no channel lights nothing and looks broken.
    private func shadowMaskRow(_ label: String, _ mask: SceneLightMask,
                               set: @escaping (SceneLightMask) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            // Indexed, so the eight boxes are drawn in channel order on every
            // launch. A Set of channels would iterate in whatever order this
            // process's hash seed produced — `CLAUDE.md` records that scar.
            ForEach(SceneLightMask.channels.indices, id: \.self) { index in
                let channel = SceneLightMask.channels[index]
                let on = mask.contains(channel)
                Button {
                    var next = mask
                    if on { next.remove(channel) } else { next.insert(channel) }
                    set(next)
                } label: {
                    Text("\(index + 1)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(on ? UM.accent.opacity(0.8) : UM.surfaceInset)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(on ? Color.white : UM.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    /// Whether this layer's own material has a map the renderer will use.
    ///
    /// The ASSET has to resolve, not merely be named: a map deleted on disk
    /// leaves the surface flat, and the inspector should say the same thing the
    /// renderer does rather than show a strength slider for relief that is not
    /// there.
    private func hasNormalMap(_ layer: SceneLayer) -> Bool {
        guard let id = layer.material.normalMapAssetID else { return false }
        return assetManager.asset(for: id) != nil
    }

    private func normalMapRow(_ layer: SceneLayer) -> some View {
        mapPickerRow(
            label: "Normal Map",
            selected: layer.material.normalMapAssetID,
            display: normalMapName(layer),
            // ONLY THE MAPS. Offering artwork here would let an artist pick a
            // drawing as a normal map, which decodes every pixel of it as a
            // direction and lights the card by its colours.
            options: assetManager.normalMapAssets,
            emptyHint: "Import a file named …_n.png"
        ) { next in
            update(layer) { $0.material.normalMapAssetID = next }
        }
    }

    private func heightMapRow(_ layer: SceneLayer) -> some View {
        mapPickerRow(
            label: "Height Map",
            selected: layer.material.heightMapAssetID,
            display: heightMapName(layer),
            // ONLY THE HEIGHT FIELDS, for the sharper version of the same
            // reason: the march reads a picked drawing's BRIGHTNESS as depth,
            // so every dark region of it becomes a hole.
            options: assetManager.heightMapAssets,
            emptyHint: "Import a file named …_h.png"
        ) { next in
            update(layer) { $0.material.heightMapAssetID = next }
        }
    }

    /// The one row both map pickers are.
    ///
    /// WRITTEN ONCE, because the two differ in four strings and in nothing
    /// else that matters -- and the parts that do matter are the parts a second
    /// copy gets wrong quietly: that "None" clears the id rather than leaving
    /// it, that the list offers ONLY assets of the right role, and that the
    /// label reads what the RENDERER will do rather than what the id says.
    ///
    /// `display` is passed in rather than derived here, because the two rows
    /// answer "nothing picked" differently: a normal map has no fallback and
    /// reads "None", while a height map can fall through to the normal map's
    /// alpha and reads "From normal alpha".
    private func mapPickerRow(label: String,
                              selected: UUID?,
                              display: String,
                              options: [TextureAsset],
                              emptyHint: String,
                              set: @escaping (UUID?) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            Menu {
                Button("None") { set(nil) }
                if options.isEmpty {
                    Text(emptyHint)
                } else {
                    Divider()
                    ForEach(options) { asset in
                        Button(asset.name) { set(asset.id) }
                    }
                }
            } label: {
                menuLabel(display, muted: selected == nil,
                          thumbnailID: selected, showsThumbnail: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    /// What the row reads when the map is set, missing, or absent.
    ///
    /// A NAMED-BUT-MISSING MAP SAYS SO. Falling back to "None" would tell the
    /// artist they never set one, and they would set it again and watch nothing
    /// happen, because the file is what moved.
    private func normalMapName(_ layer: SceneLayer) -> String {
        guard let id = layer.material.normalMapAssetID else { return "None" }
        return assetManager.asset(for: id)?.name ?? "Missing file"
    }

    @ViewBuilder
    private func thumbnail(_ assetID: UUID?) -> some View {
        if let assetID, let image = assetManager.thumbnail(assetID: assetID, maxPixel: 32) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(UM.textPrimary.opacity(0.08))
                .frame(width: 16, height: 16)
        }
    }

    private enum SliderFormat { case percent, multiple }

    /// A material slider that leaves exactly ONE step on the undo stack.
    ///
    /// `updateSceneComposition(undoable: true)` pushes a snapshot every time it
    /// is called and `interactionPushed` does not hold it back, so a slider
    /// wired the obvious way buries the artist's previous action under sixty
    /// steps a second. `onEditingChanged` brackets the gesture: one push at the
    /// start, nothing during, and the drag becomes one undo.
    private func materialSlider(_ label: String, _ value: Float,
                                range: ClosedRange<Float>,
                                format: SliderFormat,
                                set: @escaping (Float, Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            Slider(
                value: Binding(get: { Double(value) },
                               set: { set(Float($0), draggingMaterial) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                onEditingChanged: { editing in
                    if editing {
                        sceneManager.beginInteraction()
                        draggingMaterial = true
                    } else {
                        draggingMaterial = false
                        sceneManager.endInteraction()
                    }
                }
            )
            Text(format == .percent
                 ? String(Int((value * 100).rounded())) + "%"
                 : String(format: "%.2f", value))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(UM.textMuted)
                .frame(width: 38, alignment: .trailing)
        }
    }

    /// `live` is true while a drag is in progress, when the snapshot has
    /// already been taken and another would only bury it.
    private func update(_ layer: SceneLayer, live: Bool = false,
                        _ change: @escaping (inout SceneLayer) -> Void) {
        sceneManager.updateSceneLayer(layer.id, in: composition.id,
                                      undoable: !live, change)
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraSection: some View {
        title("CAMERA")

        field("X", composition.camera.position.x) { value in
            sceneManager.updateSceneComposition(composition.id) { $0.camera.position.x = value }
        }
        field("Y", composition.camera.position.y) { value in
            sceneManager.updateSceneComposition(composition.id) { $0.camera.position.y = value }
        }
        field("Z", composition.camera.positionZ) { value in
            sceneManager.updateSceneComposition(composition.id) { $0.camera.positionZ = value }
        }
        field("Rotation X", degrees(composition.camera.rotation3D.x)) { value in
            sceneManager.updateSceneComposition(composition.id) {
                $0.camera.rotation3D.x = radians(value)
            }
        }
        field("Rotation Y", degrees(composition.camera.rotation3D.y)) { value in
            sceneManager.updateSceneComposition(composition.id) {
                $0.camera.rotation3D.y = radians(value)
            }
        }
        field("Rotation Z", degrees(composition.camera.rotation3D.z)) { value in
            sceneManager.updateSceneComposition(composition.id) {
                $0.camera.rotation3D.z = radians(value)
            }
        }
        // Clamped where it is set as well as on load: a fov of 0 divides by
        // tan(0), and the field is the one place an artist can type it.
        field("FOV", composition.camera.fieldOfView) { value in
            sceneManager.updateSceneComposition(composition.id) {
                $0.camera.fieldOfView = min(max(value, 1), 170)
            }
        }

        Text("Parallax comes from the gap between a layer's Z and the camera's. "
             + "A layer twice as far draws half as big and slides half as much.")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(UM.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Bits

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(UM.textSecondary)
            .padding(.top, 2)
    }

    private func field(_ label: String, _ value: Float, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            TextField("", value: Binding(
                get: { value },
                // A field that will not parse keeps the value it had rather
                // than resetting the layer to zero under the artist's cursor.
                set: { next in if next.isFinite { set(next) } }
            ), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(UM.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(UM.surfaceInset)
                )
        }
    }

    private func degrees(_ radians: Float) -> Float { radians * 180 / .pi }
    private func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
}
