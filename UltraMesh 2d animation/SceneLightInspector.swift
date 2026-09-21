import SwiftUI
import simd

/// The set's lights: the list, and the selected one's properties.
///
/// A list and not a hierarchy, and the order in it is load-bearing rather than
/// decorative — `multiply` and `screen` lights apply in sequence, so moving one
/// up or down changes the picture. The arrows are there for that reason and the
/// footnote says so, because an artist who thinks the order is cosmetic will
/// eventually find it is not, at the least convenient moment.
struct SceneLightInspector: View {
    @EnvironmentObject private var appState: AppState

    let composition: SceneComposition

    private var sceneManager: SceneManager { appState.sceneManager }
    private var selected: SceneLight? {
        sceneManager.sceneSelection.lightID.flatMap { composition.light($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ambientSection
            if composition.lights.isEmpty {
                Text("No lights. The scene renders at full ambient, exactly as "
                     + "it did before lighting existed.")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(UM.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                lightList
            }
            if let light = selected {
                Divider().overlay(UM.textPrimary.opacity(0.08))
                properties(light)
            }
        }
    }

    // MARK: - Header and list

    private var header: some View {
        HStack(spacing: 6) {
            Text("LIGHTS")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(UM.textSecondary)
            Spacer()
            ForEach(SceneLightKind.allCases) { kind in
                Button {
                    sceneManager.addSceneLight(kind: kind, to: composition.id)
                } label: {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(UM.textSecondary)
                .help("Add a \(kind.title) light")
            }
        }
    }

    private var lightList: some View {
        VStack(spacing: 3) {
            ForEach(composition.lights) { light in
                lightRow(light)
            }
            Text("Applied top to bottom. Multiply and screen lights depend on "
                 + "what is above them.")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(UM.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func lightRow(_ light: SceneLight) -> some View {
        let isSelected = sceneManager.sceneSelection == .light(light.id)
        return HStack(spacing: 6) {
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
                .font(.system(size: 10))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 14)

            Text(light.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(light.isEnabled ? UM.textPrimary : UM.textMuted)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(light.mask.channelNumbers.map(String.init).joined(separator: ","))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(UM.textMuted)

            Button {
                sceneManager.moveSceneLight(light.id, in: composition.id, forward: false)
            } label: { Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(UM.textMuted)
            Button {
                sceneManager.moveSceneLight(light.id, in: composition.id, forward: true)
            } label: { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(UM.textMuted)
            Button {
                sceneManager.removeSceneLight(light.id, from: composition.id)
            } label: { Image(systemName: "trash").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(UM.dangerAccent)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? UM.surfaceInset : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { sceneManager.selectSceneLight(light.id) }
    }

    // MARK: - Ambient

    @ViewBuilder
    private var ambientSection: some View {
        HStack(spacing: 8) {
            Text("Ambient")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { color(composition.ambient.color) },
                set: { next in
                    sceneManager.updateSceneComposition(composition.id) {
                        $0.ambient.color = components(next)
                    }
                }
            ), supportsOpacity: false)
                .labelsHidden()
            slider(composition.ambient.intensity, range: 0...2) { value in
                sceneManager.updateSceneComposition(composition.id) {
                    $0.ambient.intensity = value
                }
            }
        }
        Text("1.0 is untouched artwork. Lower it to make the lights visible; "
             + "0 is pure black where nothing reaches.")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(UM.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The selected light

    @ViewBuilder
    private func properties(_ light: SceneLight) -> some View {
        let id = light.id

        HStack(spacing: 8) {
            Text("Colour")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { color(light.color) },
                set: { next in
                    sceneManager.updateSceneLight(id, in: composition.id) {
                        $0.color = components(next)
                    }
                }
            ), supportsOpacity: false)
                .labelsHidden()
            Spacer()
        }

        picker("Blend", SceneLightBlend.allCases, light.blend, \.title) { next in
            sceneManager.updateSceneLight(id, in: composition.id) { $0.blend = next }
        }

        field("Intensity", light.intensity) { value in
            sceneManager.updateSceneLight(id, in: composition.id) { $0.intensity = max(value, 0) }
        }

        if light.kind.isPositional {
            field("X", light.position.x) { value in
                sceneManager.updateSceneLight(id, in: composition.id) { $0.position.x = value }
            }
            field("Y", light.position.y) { value in
                sceneManager.updateSceneLight(id, in: composition.id) { $0.position.y = value }
            }
            field("Z", light.positionZ) { value in
                sceneManager.updateSceneLight(id, in: composition.id) { $0.positionZ = value }
            }
            field("Radius", light.radius) { value in
                sceneManager.updateSceneLight(id, in: composition.id) { $0.radius = max(value, 0) }
            }
            labelled("Softness") {
                slider(light.softness, range: 0...1) { value in
                    sceneManager.updateSceneLight(id, in: composition.id) { $0.softness = value }
                }
            }
            falloffRow(light)
        }

        if light.kind != .point {
            field("Direction", degrees(light.azimuth)) { value in
                sceneManager.updateSceneLight(id, in: composition.id) { $0.azimuth = radians(value) }
            }
            field("Elevation", degrees(light.elevation)) { value in
                sceneManager.updateSceneLight(id, in: composition.id) {
                    $0.elevation = radians(value)
                }
            }
        }

        if light.kind == .spot {
            // Written back as a PAIR. Typing an inner angle past the outer would
            // run the cone's smoothstep backwards and light the spot inside out,
            // so the two are clamped against each other here as well as on load.
            field("Inner Angle", degrees(light.innerAngle)) { value in
                sceneManager.updateSceneLight(id, in: composition.id) {
                    $0.innerAngle = min(max(radians(value), 0), $0.outerAngle)
                }
            }
            field("Outer Angle", degrees(light.outerAngle)) { value in
                sceneManager.updateSceneLight(id, in: composition.id) {
                    $0.outerAngle = min(max(radians(value), 0), .pi)
                    $0.innerAngle = min($0.innerAngle, $0.outerAngle)
                }
            }
        }

        labelled("Depth") {
            slider(light.depthInfluence, range: 0...1) { value in
                sceneManager.updateSceneLight(id, in: composition.id) { $0.depthInfluence = value }
            }
        }
        labelled("Surface") {
            slider(light.normalInfluence, range: 0...1) { value in
                sceneManager.updateSceneLight(id, in: composition.id) { $0.normalInfluence = value }
            }
        }

        maskRow("Affects", light.mask) { next in
            sceneManager.updateSceneLight(id, in: composition.id) { $0.mask = next }
        }

        // OFF BY DEFAULT, AND THAT IS THE PERFORMANCE DECISION. Shadowing costs
        // one plane intersection and one texture read per fragment, per light,
        // per occluder. A light that never asked for it skips the whole loop,
        // so every project made before shadows existed pays exactly nothing.
        Toggle("Casts Shadows", isOn: Binding(
            get: { light.castsShadows },
            set: { next in
                sceneManager.updateSceneLight(id, in: composition.id) {
                    $0.castsShadows = next
                }
            }
        ))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(UM.textPrimary)

        if light.castsShadows {
            Text("Only layers with a Shadow Cast channel block this light, and "
                 + "only layers with a matching Shadowed channel darken. Depth 0 "
                 + "casts nothing — a flat 2D light has no depth to cast through.")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(UM.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("Depth 0 lights every layer as though it sat at the light's own "
             + "depth; 1 makes it a real point in space. Surface 0 is flat 2D "
             + "lighting; 1 is full Lambert on the card's facing.")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(UM.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The falloff presets, plus what the current curve is.
    ///
    /// Presets rather than an embedded editor: the curve IS an `AnimationCurve`,
    /// so the place to shape it is the Graph editor the rest of the project is
    /// eased in, not a second little curve widget living in a sidebar.
    @ViewBuilder
    private func falloffRow(_ light: SceneLight) -> some View {
        HStack(spacing: 8) {
            Text("Falloff")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            ForEach(Array(SceneLightInspector.falloffPresets.enumerated()), id: \.offset) { entry in
                let isCurrent = light.falloff == entry.element.curve
                Button {
                    sceneManager.updateSceneLight(light.id, in: composition.id) {
                        $0.falloff = entry.element.curve
                    }
                } label: {
                    Text(entry.element.name)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isCurrent ? UM.surfaceInset : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isCurrent ? UM.textPrimary : UM.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    static let falloffPresets: [(name: String, curve: LightFalloffCurve)] = [
        ("Smooth", .smooth), ("Linear", .linear), ("Inv²", .inverseSquare),
    ]

    // MARK: - Bits

    private func maskRow(_ label: String, _ mask: SceneLightMask,
                         set: @escaping (SceneLightMask) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            // Indexed, so the eight boxes are drawn in channel order every
            // launch. A Set of channels would iterate in whatever order this
            // process's hash seed produced.
            ForEach(SceneLightMask.channels.indices, id: \.self) { index in
                let channel = SceneLightMask.channels[index]
                let on = mask.contains(channel)
                Button {
                    var next = mask
                    if on { next.remove(channel) } else { next.insert(channel) }
                    // Never all off: a light on no channel lights nothing, and
                    // it looks exactly like the light being broken.
                    set(next.isEmpty ? channel : next)
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

    private func labelled<Content: View>(_ label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            content()
        }
    }

    private func slider(_ value: Float, range: ClosedRange<Float>,
                        set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 6) {
            Slider(value: Binding(get: { Double(value) },
                                  set: { set(Float($0)) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text(String(Int((value * 100).rounded())) + "%")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(UM.textMuted)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func picker<T: Hashable & Identifiable>(
        _ label: String, _ options: [T], _ current: T,
        _ title: KeyPath<T, String>, set: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            Picker("", selection: Binding(get: { current }, set: set)) {
                ForEach(options) { option in
                    Text(option[keyPath: title]).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 10.5, weight: .medium))
        }
    }

    private func field(_ label: String, _ value: Float,
                       set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 74, alignment: .leading)
            TextField("", value: Binding(
                get: { value },
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

    private func color(_ rgb: SIMD3<Float>) -> Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    /// A SwiftUI colour back to three floats.
    ///
    /// Through `.sRGB` explicitly rather than by reading whatever space the
    /// picker hands back: the renderer multiplies these numbers straight into
    /// pixels that are themselves sRGB, so a colour that arrived in a display
    /// space would tint every light on a wide-gamut screen and nowhere else.
    private func components(_ color: Color) -> SIMD3<Float> {
        #if canImport(AppKit)
        let native = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return SIMD3<Float>(Float(native.redComponent),
                            Float(native.greenComponent),
                            Float(native.blueComponent))
        #else
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
        #endif
    }

    private func degrees(_ radians: Float) -> Float { radians * 180 / .pi }
    private func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
}
