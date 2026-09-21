import SwiftUI

/// Events panel.
///
/// Event definitions live on the skeleton and are shared by every animation, so
/// they are managed here rather than per clip. Keying an event places it on the
/// timeline at the playhead; the timeline then owns moving, copying and deleting
/// it like any other keyframe.
struct EventsPanelView: View {
    @ObservedObject var sceneManager: SceneManager

    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    @State private var expandedID: UUID?

    private let accent = Color(red: 0.95, green: 0.75, blue: 0.36)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if sceneManager.animationEvents.isEmpty {
                    Text("No events yet. Events fire at an exact frame during playback — footsteps, effects, or handing control back to game code.")
                        .font(.system(size: 10))
                        .foregroundStyle(UM.textPrimary.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(sceneManager.animationEvents) { event in
                        eventRow(event)
                    }
                }

                if !sceneManager.recentlyFiredEvents.isEmpty {
                    Divider().overlay(UM.textPrimary.opacity(0.06))
                    firedList
                }
            }
            .padding(12)
        }
    }

    private var header: some View {
        HStack {
            Text("EVENTS")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .kerning(0.6)
                .foregroundStyle(UM.textPrimary.opacity(0.45))
            Spacer()
            Button {
                sceneManager.createAnimationEvent()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
        }
    }

    @ViewBuilder
    private func eventRow(_ event: AnimationEvent) -> some View {
        let hasKeyHere = sceneManager.eventHasKeyAtPlayhead(event.id)
        let isExpanded = expandedID == event.id

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button {
                    if hasKeyHere {
                        sceneManager.removeEventKeyAtPlayhead(event.id)
                    } else {
                        sceneManager.keyEvent(event.id)
                    }
                } label: {
                    Image(systemName: hasKeyHere ? "diamond.fill" : "diamond")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hasKeyHere ? accent : UM.textPrimary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help(hasKeyHere ? "Remove key at playhead" : "Key event at playhead")

                if renamingID == event.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .onSubmit {
                            sceneManager.renameAnimationEvent(event.id, to: renameText)
                            renamingID = nil
                        }
                } else {
                    Text(event.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.9))
                }

                Spacer(minLength: 0)

                Button {
                    expandedID = isExpanded ? nil : event.id
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.4))
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Rename") {
                        renameText = event.name
                        renamingID = event.id
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        sceneManager.deleteAnimationEvent(event.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.45))
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if isExpanded {
                defaultsEditor(event)
                if hasKeyHere {
                    Divider().overlay(UM.textPrimary.opacity(0.05))
                    payloadEditor(event)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(UM.textPrimary.opacity(0.04))
        )
    }

    /// Values inherited by every key that does not override them.
    @ViewBuilder
    private func defaultsEditor(_ event: AnimationEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("DEFAULTS")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(UM.textPrimary.opacity(0.35))

            HStack(spacing: 6) {
                labelledField("Int", value: Binding(
                    get: { Double(event.defaultInt) },
                    set: { newValue in
                        sceneManager.updateAnimationEvent(event.id) { $0.defaultInt = Int(newValue) }
                    }
                ))
                labelledField("Float", value: Binding(
                    get: { Double(event.defaultFloat) },
                    set: { newValue in
                        sceneManager.updateAnimationEvent(event.id) { $0.defaultFloat = Float(newValue) }
                    }
                ))
            }

            TextField("String", text: Binding(
                get: { event.defaultString },
                set: { newValue in
                    sceneManager.updateAnimationEvent(event.id) { $0.defaultString = newValue }
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(UM.textPrimary.opacity(0.06))
            )
        }
    }

    /// Per-key overrides. A blank field means "inherit the default", which is
    /// why these are cleared rather than zeroed when the artist empties them.
    @ViewBuilder
    private func payloadEditor(_ event: AnimationEvent) -> some View {
        let payload = sceneManager.eventPayloadAtPlayhead(event.id) ?? .inheritingDefaults

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("THIS KEY")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(UM.textPrimary.opacity(0.35))
                Spacer()
                if payload.overridesAnything {
                    Button("Reset to defaults") {
                        sceneManager.setEventPayloadAtPlayhead(event.id, .inheritingDefaults)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(accent.opacity(0.8))
                }
            }

            HStack(spacing: 6) {
                overrideField(
                    "Int",
                    text: Binding(
                        get: { payload.intValue.map(String.init) ?? "" },
                        set: { newValue in
                            var next = payload
                            next.intValue = newValue.isEmpty ? nil : Int(newValue)
                            sceneManager.setEventPayloadAtPlayhead(event.id, next)
                        }
                    ),
                    placeholder: "\(event.defaultInt)"
                )
                overrideField(
                    "Float",
                    text: Binding(
                        get: { payload.floatValue.map { String($0) } ?? "" },
                        set: { newValue in
                            var next = payload
                            next.floatValue = newValue.isEmpty ? nil : Float(newValue)
                            sceneManager.setEventPayloadAtPlayhead(event.id, next)
                        }
                    ),
                    placeholder: String(event.defaultFloat)
                )
            }

            overrideField(
                "String",
                text: Binding(
                    get: { payload.stringValue ?? "" },
                    set: { newValue in
                        var next = payload
                        next.stringValue = newValue.isEmpty ? nil : newValue
                        sceneManager.setEventPayloadAtPlayhead(event.id, next)
                    }
                ),
                placeholder: event.defaultString.isEmpty ? "—" : event.defaultString
            )
        }
    }

    /// Live readout of what playback has crossed, so an artist can confirm an
    /// event fires where they expect without wiring up a runtime.
    private var firedList: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("FIRED")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(UM.textPrimary.opacity(0.35))
                Spacer()
                Button("Clear") { sceneManager.clearFiredEvents() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(UM.textPrimary.opacity(0.45))
            }

            ForEach(Array(sceneManager.recentlyFiredEvents.enumerated().reversed()), id: \.offset) { _, fired in
                HStack(spacing: 6) {
                    Text("\(fired.frame)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.85))
                        .frame(width: 28, alignment: .trailing)
                    Text(fired.name)
                        .font(.system(size: 10))
                        .foregroundStyle(UM.textPrimary.opacity(0.75))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Field helpers

    private func labelledField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(UM.textPrimary.opacity(0.4))
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(UM.textPrimary.opacity(0.06))
        )
    }

    private func overrideField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(UM.textPrimary.opacity(0.4))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(UM.textPrimary.opacity(0.06))
        )
    }
}
