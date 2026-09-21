import SwiftUI

/// The top bar, laid out as three fixed regions: wordmark, canvas modes, history.
///
/// Everything else that used to live here moved to where it is used. Import PNG
/// is in the Hierarchy panel's empty state and the File menu, Show Bones floats
/// over the canvas it affects, and Constraints became a tab in the Inspector.
/// The bar had grown into a shelf where unrelated buttons were parked because
/// there was room.
struct EditorToolbarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var toolManager: ToolManager

    let leftPanelWidth: CGFloat
    let rightPanelWidth: CGFloat
    let isInspectorVisible: Bool
    let onToggleInspector: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                UltraMeshWordmark()

                ProjectMenuButton()

                // Reserves the middle for the centred mode strip drawn below,
                // which takes no part in this row's layout.
                Spacer(minLength: 300)

                HStack(spacing: 10) {
                    // Only shown while the Inspector is closed — the panel's own
                    // header carries the close control, so this is the way back.
                    if !isInspectorVisible {
                        RoundToolbarButton(systemImage: "sidebar.right", action: onToggleInspector)
                    }
                    RoundToolbarButton(
                        systemImage: "arrow.uturn.backward",
                        isEnabled: sceneManager.canUndo,
                        action: { sceneManager.undo() }
                    )
                    .keyboardShortcut("z", modifiers: .command)

                    RoundToolbarButton(
                        systemImage: "arrow.uturn.forward",
                        isEnabled: sceneManager.canRedo,
                        action: { sceneManager.redo() }
                    )
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                }
            }
            .zIndex(1)

            // Centred in the ZStack, not sequenced in the HStack: the wordmark
            // on the left is a fixed width but the history group on the right
            // gains a button when the Inspector closes, so anything laid out
            // between them would shift.
            // Bones / Mesh / Pose are rig work; Scene stages finished rigs
            // and has no use for any of them, so the strip goes away entirely
            // rather than showing three disabled buttons.
            // Editor | Animator, in the toolbar's own chrome. The canvas modes
            // that used to sit here — Mesh and Pose — are buttons on the canvas
            // now, beside Bones and Weights, because they are all things you do
            // by working on the artwork.
            EditorModeSwitch(mode: $appState.editorMode, variant: .toolbar)
                .fixedSize()
                .zIndex(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(UM.surface)
        .overlay(
            Rectangle().fill(UM.hairline).frame(height: 1),
            alignment: .bottom
        )
    }
}

/// The File menu, for the platform that does not have one.
///
/// Open, Save, Save As, Import PNG, Export and Settings were reachable through
/// exactly one thing: the `.commands` block in the app entry point. That whole
/// block is `#if os(macOS)`, and iPadOS has no menu bar — so on iPad there was
/// no way to press any of them. None of the file handling was missing: the
/// unified iOS picker, the save sheet and the folder picker are all there and
/// all wired to these same calls. There was simply nothing to tap.
///
/// The doc comment on the toolbar recorded how it happened, in passing: "Import
/// PNG is in the Hierarchy panel's empty state and the File menu" — true, and
/// on iPad that means Import PNG works right up until the first image lands and
/// the empty state disappears.
///
/// Shown on every platform rather than behind `#if os(iOS)`. A second route on
/// the Mac costs one button, and it leaves `verify_ios_reachability.py` with a
/// rule that has no platform exception to argue about.
struct ProjectMenuButton: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Menu {
            Button {
                appState.requestNewProject()
            } label: {
                Label("New Project", systemImage: "doc.badge.plus")
            }

            Button {
                appState.openProject()
            } label: {
                Label("Open Project…", systemImage: "folder")
            }

            Divider()

            Button {
                appState.saveProject()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }

            Button {
                appState.saveProjectAs()
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down.on.square")
            }

            Divider()

            Button {
                appState.importPNG()
            } label: {
                Label("Import PNG…", systemImage: "photo.badge.plus")
            }

            Divider()

            Button {
                appState.showExportDialog()
            } label: {
                Label("Export…", systemImage: "arrow.up.doc")
            }

            Button {
                appState.exportSkeleton()
            } label: {
                Label("Export Skeleton (.umesh)…", systemImage: "figure.walk")
            }

            Button {
                appState.exportPNGSequence()
            } label: {
                Label("Export PNG Sequence…", systemImage: "square.stack.3d.down.right")
            }

            // Parked with the mode it exports. Gated on the same list, so
            // re-enabling Scene brings its export back without a second edit.
            if EditorMode.selectable.contains(.scene) {
                Button {
                    appState.exportSceneVideo()
                } label: {
                    Label("Export Scene Video…", systemImage: "film")
                }
            }

            Divider()

            Button {
                appState.showSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(0.78))
                .frame(width: 34, height: 34)
                .background(Circle().fill(UM.accentSoft))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Project")
    }
}

/// Glyph plus wordmark.
struct UltraMeshWordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            UltraMeshMarkView()
                .frame(width: 28, height: 29)
            Text("UltraMesh")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(UM.textPrimary)
                .fixedSize()
        }
    }
}

/// Circular icon button, as the mockup draws undo and redo.
struct RoundToolbarButton: View {
    let systemImage: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? UM.textPrimary.opacity(0.78) : UM.textMuted)
                .frame(width: 34, height: 34)
                .background(Circle().fill(UM.accentSoft.opacity(isEnabled ? 1.0 : 0.45)))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
