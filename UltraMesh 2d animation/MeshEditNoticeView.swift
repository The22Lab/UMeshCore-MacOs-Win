import SwiftUI

/// The banner that tells the artist an edit was refused.
///
/// The rejection message existed on `SceneManager` and was set in two places,
/// but nothing in the app ever read it, so a refused edit looked exactly like a
/// dead button. The invariant in CLAUDE.md is that an edit which breaks a mesh
/// invariant is rejected *and the artist is told*; this is the second half.
///
/// It carries outcomes as well as refusals now. Auto Bind can succeed and still
/// have deliberately left a bone to an overlapping image, and from the canvas
/// that is indistinguishable from a bone the detection missed.
///
/// It sits at the bottom-centre of the canvas: clear of the coordinate panel at
/// the bottom-left, clear of the mode switch and the IK builder at the top, and
/// in the one place the eye is not while dragging vertices.
struct MeshEditNoticeView: View {
    let notice: SceneManager.MeshEditNotice
    let onDismiss: () -> Void

    /// Warnings carry the brand magenta the rest of the app uses for refusals;
    /// outcomes carry the accent, so "Auto Bind bound four bones" does not read
    /// as something having gone wrong.
    private var tint: Color {
        notice.isWarning ? UM.brandMagenta : UM.accentStrong
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isWarning
                  ? "exclamationmark.triangle.fill"
                  : "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)

            Text(notice.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(UM.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(UM.textMuted)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(UM.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: tint.opacity(0.22), radius: 14, y: 4)
    }
}
