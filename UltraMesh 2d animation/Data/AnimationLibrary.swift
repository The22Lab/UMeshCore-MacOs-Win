import Foundation
import Combine

/// A named snapshot of every animation timeline in the scene: the per-bone and
/// per-sprite clips, plus the scene-wide clip that owns constraint property and
/// draw order timelines, plus the authored constraint values those timelines
/// blend away from.
///
/// The scene clip and the setup values must travel together with the rest of
/// the snapshot: without them, switching animations would silently drop every
/// constraint and draw order key, and leave constraints stranded at whatever
/// value the outgoing animation last evaluated.
struct NamedAnimation: Identifiable, Equatable {
    let id: UUID
    var name: String
    var boneClips: [UUID: AnimationClip]
    var imageClips: [UUID: AnimationClip]
    /// Constraint property and draw order timelines.
    var sceneClip: AnimationClip
    /// Authored constraint values captured when a property was first keyed.
    var constraintSetupValues: [UUID: ConstraintSetupValues]
    var duration: Int

    init(
        id: UUID,
        name: String,
        boneClips: [UUID: AnimationClip],
        imageClips: [UUID: AnimationClip],
        sceneClip: AnimationClip = AnimationClip(name: "Scene"),
        constraintSetupValues: [UUID: ConstraintSetupValues] = [:],
        duration: Int
    ) {
        self.id = id
        self.name = name
        self.boneClips = boneClips
        self.imageClips = imageClips
        self.sceneClip = sceneClip
        self.constraintSetupValues = constraintSetupValues
        self.duration = duration
    }
}

@MainActor
final class AnimationLibrary: ObservableObject {
    @Published private(set) var animations: [NamedAnimation] = []
    @Published private(set) var activeID: UUID?

    unowned let scene: SceneManager

    init(scene: SceneManager) {
        self.scene = scene
    }

    var active: NamedAnimation? {
        animations.first(where: { $0.id == activeID })
    }

    /// Puts a saved library back, as-is.
    ///
    /// Deliberately does NOT snapshot the live clips first: the project was just
    /// loaded, so those clips ARE the active animation's, and snapshotting them
    /// over the list would overwrite what was read from the file with a copy of
    /// one of its own entries.
    func restore(animations: [NamedAnimation], activeID: UUID?) {
        self.animations = animations
        // An id that names nothing would leave the panel pointing at an entry
        // that is not there; fall back to no selection rather than a dangling one.
        self.activeID = animations.contains(where: { $0.id == activeID }) ? activeID : nil
    }

    /// Captures the current state of all bone/image animationClips into a new animation.
    func createFromCurrentState(name: String) {
        let animation = snapshotCurrent(name: name)
        // Persist current edits into the previously active animation so they aren't lost.
        if let activeID, let idx = animations.firstIndex(where: { $0.id == activeID }) {
            animations[idx] = snapshotCurrent(name: animations[idx].name, id: activeID)
        }
        animations.append(animation)
        activeID = animation.id
    }

    /// Switches active animation; saves current edits into the outgoing snapshot,
    /// then loads keyframes from the target into scene clips.
    /// No-ops (but still saves) when already on the target animation, so the scene's
    /// live clips are never overwritten with a stale library snapshot.
    func switchTo(_ id: UUID) {
        if let activeID, let idx = animations.firstIndex(where: { $0.id == activeID }) {
            animations[idx] = snapshotCurrent(name: animations[idx].name, id: activeID)
        }
        guard activeID != id else { return }
        guard let target = animations.first(where: { $0.id == id }) else { return }
        applyToScene(target)
        activeID = id
    }

    func rename(_ id: UUID, to newName: String) {
        guard let idx = animations.firstIndex(where: { $0.id == id }) else { return }
        animations[idx].name = newName
    }

    func delete(_ id: UUID) {
        animations.removeAll { $0.id == id }
        if activeID == id { activeID = animations.first?.id }
        if let next = active { applyToScene(next) }
    }

    // MARK: - Internal

    private func snapshotCurrent(name: String, id: UUID = UUID()) -> NamedAnimation {
        var bones: [UUID: AnimationClip] = [:]
        var images: [UUID: AnimationClip] = [:]
        var duration = 0
        for b in scene.skeleton.orderedBones {
            bones[b.id] = b.animationClip
            duration = max(duration, b.animationClip.durationInFrames)
        }
        for img in scene.images {
            images[img.id] = img.animationClip
            duration = max(duration, img.animationClip.durationInFrames)
        }
        let sceneClip = scene.sceneAnimationClip
        duration = max(duration, sceneClip.durationInFrames)
        return NamedAnimation(
            id: id,
            name: name,
            boneClips: bones,
            imageClips: images,
            sceneClip: sceneClip,
            constraintSetupValues: scene.constraintSetupValues,
            duration: duration
        )
    }

    private func applyToScene(_ anim: NamedAnimation) {
        for boneID in scene.skeleton.orderedBones.map(\.id) {
            let clip = anim.boneClips[boneID] ?? AnimationClip(name: anim.name)
            scene.skeleton.bones[boneID]?.animationClip = clip
        }
        for imgID in scene.images.map(\.id) {
            scene.updateImage(id: imgID) { img in
                img.animationClip = anim.imageClips[imgID] ?? AnimationClip(name: anim.name)
            }
        }
        // Restore the constraints to their authored values before installing the
        // incoming timelines, so a property animated by the outgoing animation
        // but untouched by the incoming one does not keep a stale value.
        scene.restoreAllConstraintSetupValues()
        scene.replaceSceneAnimation(
            clip: anim.sceneClip,
            constraintSetupValues: anim.constraintSetupValues
        )
        scene.setCurrentFrame(scene.currentFrame)
    }
}
