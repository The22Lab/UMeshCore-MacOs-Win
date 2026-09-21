import SwiftUI

/// The attachments of the selected sprite's slot, and which one is showing.
///
/// A slot is a set of sprites that are variants of one attachment point — eyes
/// open and eyes shut, an open hand and a fist. The grouping already existed
/// (`SceneImage.slotName`, grouped in the Skins panel) and the skins already
/// chose between them; what this adds is choosing per FRAME.
///
/// One verb, two meanings, decided by the mode rather than by the artist:
/// clicking an attachment in Editor edits the active skin, and in Animator it
/// keys the attachment timeline at the playhead. That is what makes this a
/// workflow rather than two features.
struct AttachmentsPanel: View {
    @ObservedObject var sceneManager: SceneManager
    /// The sprite the artist has selected; its slot is the one shown.
    let image: SceneImage

    private var slotName: String { image.effectiveSlotName }
    private var attachments: [SceneImage] { sceneManager.attachments(inSlot: slotName) }
    private var shown: UUID? { sceneManager.shownAttachment(inSlot: slotName) }
    private var isAnimating: Bool { sceneManager.isAnimationEditingEnabled }

    var body: some View {
        // A slot of one is just a sprite. Showing a chooser with a single
        // choice in it teaches the artist nothing and takes up the panel.
        if attachments.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                header
                ForEach(attachments) { attachment in
                    row(attachment)
                }
                emptyRow
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("ATTACHMENTS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(UM.textSecondary)
            Text(slotName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(UM.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            keyButton
        }
    }

    /// Keys the slot as it stands, or clears the key at the playhead.
    ///
    /// Only in Animator: in Editor there is no playhead to key against, and a
    /// key button that does nothing is worse than one that is not there.
    @ViewBuilder
    private var keyButton: some View {
        if isAnimating {
            let keyed = sceneManager.attachmentHasKeyAtPlayhead(slot: slotName)
            Button {
                if keyed {
                    sceneManager.removeAttachmentKeyAtPlayhead(slot: slotName)
                } else {
                    sceneManager.keyAttachment(slot: slotName, imageID: shown)
                }
            } label: {
                Image(systemName: keyed ? "diamond.fill" : "diamond")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(keyed ? UM.accentStrong : UM.textMuted)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(keyed ? "Remove this slot's key at the playhead"
                        : "Key which attachment this slot shows")
        }
    }

    private func row(_ attachment: SceneImage) -> some View {
        let isShown = shown == attachment.id
        return Button {
            sceneManager.showAttachment(slot: slotName, imageID: attachment.id)
        } label: {
            HStack(spacing: 7) {
                ImageGlyph()
                    .frame(width: 14, height: 14)
                    .opacity(isShown ? 1 : 0.45)
                Text(attachment.name)
                    .font(.system(size: 10.5, weight: isShown ? .semibold : .regular))
                    .foregroundStyle(isShown ? UM.textPrimary : UM.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isShown {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(UM.accentStrong)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isShown ? UM.accentSoft.opacity(0.55) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(isAnimating
              ? "Show \(attachment.name) from this frame on"
              : "Show \(attachment.name) in the active skin")
    }

    /// A slot can show NOTHING, and that is a choice rather than an absence —
    /// a hand with no held object, an eye socket with the eye removed. That is
    /// why the key payload is optional rather than a plain id.
    private var emptyRow: some View {
        Button {
            sceneManager.showAttachment(slot: slotName, imageID: nil)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "slash.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(shown == nil ? UM.accentStrong : UM.textMuted)
                    .frame(width: 14)
                Text("None")
                    .font(.system(size: 10.5, weight: shown == nil ? .semibold : .regular))
                    .foregroundStyle(shown == nil ? UM.textPrimary : UM.textMuted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(shown == nil ? UM.accentSoft.opacity(0.55) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("Show nothing in this slot")
    }
}
