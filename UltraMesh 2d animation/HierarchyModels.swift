import Foundation

struct HierarchyItem: Identifiable, Equatable {
    enum ItemType: String, CaseIterable {
        case image
        case bone
        case mesh
    }

    let id: UUID
    var name: String
    var type: ItemType
    var isHidden: Bool
    var children: [HierarchyItem]
    var order: Int

    init(
        id: UUID = UUID(),
        name: String,
        type: ItemType,
        isHidden: Bool = false,
        children: [HierarchyItem] = [],
        order: Int
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isHidden = isHidden
        self.children = children
        self.order = order
    }
}
