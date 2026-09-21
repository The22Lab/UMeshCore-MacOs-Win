import SwiftUI

struct AnimationsPanelView: View {
    @ObservedObject var library: AnimationLibrary
    @State private var newName: String = ""
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UM.textSecondary)
                Text("ANIMATIONS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(UM.textMuted)
                    .tracking(0.7)
                Spacer()
                Button {
                    let name = uniqueName("Animation")
                    library.createFromCurrentState(name: name)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(UM.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            ForEach(library.animations) { anim in
                row(anim)
            }
        }
    }

    @ViewBuilder
    private func row(_ anim: NamedAnimation) -> some View {
        let isActive = library.activeID == anim.id
        HStack(spacing: 6) {
            Image(systemName: isActive ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(isActive ? Color.orange : UM.textMuted)

            if renamingID == anim.id {
                TextField("", text: $renameDraft, onCommit: {
                    library.rename(anim.id, to: renameDraft)
                    renamingID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            } else {
                Text(anim.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? UM.textPrimary : UM.textSecondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        renameDraft = anim.name
                        renamingID = anim.id
                    }
            }
            Spacer()
            Button {
                library.delete(anim.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(UM.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(isActive ? Color.orange.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { library.switchTo(anim.id) }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(library.animations.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
