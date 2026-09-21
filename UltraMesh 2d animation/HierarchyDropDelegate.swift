import SwiftUI

struct HierarchyDropDelegate: DropDelegate {
    let item: HierarchyItem
    let sceneManager: SceneManager
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != item.id else {
            return
        }
        let orderedIDs = sceneManager.displayHierarchyIDs()
        guard let from = orderedIDs.firstIndex(of: draggingID),
              let to = orderedIDs.firstIndex(of: item.id) else {
            return
        }
        let destination = to > from ? to + 1 : to
        if destination != from {
            sceneManager.moveHierarchyItem(id: draggingID, toDisplayIndex: destination)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
