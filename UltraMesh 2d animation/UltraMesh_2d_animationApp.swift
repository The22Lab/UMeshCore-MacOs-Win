//
//  UltraMesh_2d_animationApp.swift
//  UltraMesh 2d animation
//
//  Created by Ricardo on 2026/3/31.
//

import SwiftUI

@main
struct UltraMesh_2d_animationApp: App {
    @StateObject private var appState = AppState()
    /// Day unless the artist says otherwise, so an existing install opens on
    /// exactly the interface it had.
    @AppStorage(UMAppearanceStorage.key) private var appearanceRaw = UMAppearance.light.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                // The system's own controls — sheets, alerts, pickers,
                // toggles — follow the DEVICE unless told otherwise. Left to
                // follow it, an iPad in dark mode drew white system labels
                // over the editor's light panels while a Mac in light mode
                // drew the same code correctly. So it is pinned once, at the
                // root, rather than patched view by view.
                //
                // It used to be pinned to `.light` outright, because the
                // palette only had a light half. It now follows the artist's
                // choice, and the palette resolves to match: the same single
                // decision, told to both.
                .preferredColorScheme(
                    (UMAppearance(rawValue: appearanceRaw) ?? .light).preferredColorScheme)
        }
#if os(macOS)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // REPLACING `.newItem`, not after it. SwiftUI's stock New Item
            // makes a second WINDOW on a document-based app and does nothing
            // useful here; leaving it in place would put two things called New
            // in one menu, one of which is not what anybody means by it.
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    appState.requestNewProject()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open…") {
                    appState.openProject()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appState.saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .saveItem) {
                Button("Save As…") {
                    appState.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Import PNG…") {
                    appState.importPNG()
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                Button("Export…") {
                    appState.showExportDialog()
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Export Skeleton (.umesh)…") {
                    appState.exportSkeleton()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])

                Button("Export PNG Sequence…") {
                    appState.exportPNGSequence()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
#endif
    }
}
