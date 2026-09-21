import Foundation
import simd

/// Which concrete constraint store an ID lives in. Lets generic code (timeline
/// rows, inspector key buttons, persistence) address constraints uniformly
/// without duplicating a four-way lookup at every call site.
enum ConstraintKind: String, CaseIterable, Equatable {
    case ik
    case transform
    case path
    case physics

    var title: String {
        switch self {
        case .ik:        return "IK"
        case .transform: return "Transform"
        case .path:      return "Path"
        case .physics:   return "Physics"
        }
    }

    var systemImage: String {
        switch self {
        case .ik:        return "point.topleft.down.curvedto.point.bottomright.up"
        case .transform: return "arrow.triangle.2.circlepath"
        case .path:      return "scribble"
        case .physics:   return "wind"
        }
    }

    /// Animatable properties exposed by this constraint type, in the order the
    /// inspector and the timeline list them.
    var animatableProperties: [AnimationTrackProperty] {
        switch self {
        case .ik:        return AnimationTrackProperty.ikProperties
        case .transform: return AnimationTrackProperty.transformProperties
        case .path:      return AnimationTrackProperty.pathProperties
        case .physics:   return AnimationTrackProperty.physicsProperties
        }
    }
}

/// A constraint's authored ("setup pose") values for every animatable property.
///
/// The live values stored on the constraint structs are what the solver reads,
/// and animation overwrites them every frame. Without a separate record of the
/// authored values, scrubbing away from a keyframe would leave the constraint
/// stuck at whatever the last evaluated frame produced. This mirrors exactly
/// how sprites keep `basePose` alongside their animated pose.
struct ConstraintSetupValues: Equatable {
    var scalars: [String: Float] = [:]
    var flags: [String: Bool] = [:]
    var vectors: [String: SIMD2<Float>] = [:]

    func scalar(_ property: AnimationTrackProperty) -> Float? {
        scalars[property.rawValue]
    }

    func flag(_ property: AnimationTrackProperty) -> Bool? {
        flags[property.rawValue]
    }

    func vector(_ property: AnimationTrackProperty) -> SIMD2<Float>? {
        vectors[property.rawValue]
    }

    mutating func set(_ property: AnimationTrackProperty, scalar value: Float) {
        scalars[property.rawValue] = value
    }

    mutating func set(_ property: AnimationTrackProperty, flag value: Bool) {
        flags[property.rawValue] = value
    }

    mutating func set(_ property: AnimationTrackProperty, vector value: SIMD2<Float>) {
        vectors[property.rawValue] = value
    }
}

extension Skeleton {

    // MARK: Identification

    /// The store an ID belongs to, or `nil` if no constraint has that ID.
    func constraintKind(for id: UUID) -> ConstraintKind? {
        if ikConstraints.contains(where: { $0.id == id })        { return .ik }
        if transformConstraints.contains(where: { $0.id == id }) { return .transform }
        if pathConstraints.contains(where: { $0.id == id })      { return .path }
        if physicsConstraints.contains(where: { $0.id == id })   { return .physics }
        return nil
    }

    func constraintName(for id: UUID) -> String? {
        if let c = ikConstraints.first(where: { $0.id == id })        { return c.name }
        if let c = transformConstraints.first(where: { $0.id == id }) { return c.name }
        if let c = pathConstraints.first(where: { $0.id == id })      { return c.name }
        if let c = physicsConstraints.first(where: { $0.id == id })   { return c.name }
        return nil
    }

    /// Every constraint ID paired with its kind and name, in evaluation order.
    /// Used to build timeline groups that match the solver's execution order,
    /// which is what makes debugging constraint stacks tractable.
    var constraintDirectory: [(id: UUID, kind: ConstraintKind, name: String, order: Int)] {
        var out: [(id: UUID, kind: ConstraintKind, name: String, order: Int)] = []
        out.reserveCapacity(
            ikConstraints.count + transformConstraints.count
            + pathConstraints.count + physicsConstraints.count
        )
        for c in ikConstraints        { out.append((c.id, .ik, c.name, c.order)) }
        for c in transformConstraints { out.append((c.id, .transform, c.name, c.order)) }
        for c in pathConstraints      { out.append((c.id, .path, c.name, c.order)) }
        for c in physicsConstraints   { out.append((c.id, .physics, c.name, c.order)) }
        return out.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.name < rhs.name : lhs.order < rhs.order
        }
    }

    func animatableProperties(forConstraint id: UUID) -> [AnimationTrackProperty] {
        constraintKind(for: id)?.animatableProperties ?? []
    }

    // MARK: Scalar access

    func constraintScalar(_ id: UUID, _ property: AnimationTrackProperty) -> Float? {
        if let c = ikConstraints.first(where: { $0.id == id }) {
            switch property {
            case .constraintMix: return c.mix
            case .ikSoftness:    return c.softness
            default:             return nil
            }
        }
        if let c = transformConstraints.first(where: { $0.id == id }) {
            switch property {
            case .constraintMix:         return c.mix
            case .transformTranslateMix: return c.positionMix
            case .transformRotateMix:    return c.rotationMix
            case .transformScaleMix:     return c.scaleMix
            case .transformShearMix:     return c.shearMix
            default:                     return nil
            }
        }
        if let c = pathConstraints.first(where: { $0.id == id }) {
            switch property {
            case .constraintMix:    return c.mix
            case .pathPosition:     return c.position
            case .pathSpacing:      return c.spacing
            case .pathPositionMix:  return c.positionMix
            case .pathRotateMix:    return c.rotateMix
            default:                return nil
            }
        }
        if let c = physicsConstraints.first(where: { $0.id == id }) {
            switch property {
            case .constraintMix:     return c.mix
            case .physicsMass:       return c.settings.mass
            case .physicsDamping:    return c.settings.damping
            case .physicsStiffness:  return c.settings.stiffness
            case .physicsGravity:    return c.settings.gravity
            case .physicsDrag:       return c.settings.drag
            default:                 return nil
            }
        }
        return nil
    }

    mutating func setConstraintScalar(_ id: UUID, _ property: AnimationTrackProperty, _ raw: Float) {
        let value = property.clamped(raw)

        if let index = ikConstraints.firstIndex(where: { $0.id == id }) {
            switch property {
            case .constraintMix: ikConstraints[index].mix = value
            case .ikSoftness:    ikConstraints[index].softness = value
            default:             break
            }
            return
        }
        if let index = transformConstraints.firstIndex(where: { $0.id == id }) {
            switch property {
            case .constraintMix:         transformConstraints[index].mix = value
            case .transformTranslateMix: transformConstraints[index].positionMix = value
            case .transformRotateMix:    transformConstraints[index].rotationMix = value
            case .transformScaleMix:     transformConstraints[index].scaleMix = value
            case .transformShearMix:     transformConstraints[index].shearMix = value
            default:                     break
            }
            return
        }
        if let index = pathConstraints.firstIndex(where: { $0.id == id }) {
            switch property {
            case .constraintMix:   pathConstraints[index].mix = value
            case .pathPosition:    pathConstraints[index].position = value
            case .pathSpacing:     pathConstraints[index].spacing = value
            case .pathPositionMix: pathConstraints[index].positionMix = value
            case .pathRotateMix:   pathConstraints[index].rotateMix = value
            default:               break
            }
            return
        }
        if let index = physicsConstraints.firstIndex(where: { $0.id == id }) {
            switch property {
            case .constraintMix:    physicsConstraints[index].mix = value
            case .physicsMass:      physicsConstraints[index].settings.mass = max(value, 0.0001)
            case .physicsDamping:   physicsConstraints[index].settings.damping = value
            case .physicsStiffness: physicsConstraints[index].settings.stiffness = value
            case .physicsGravity:   physicsConstraints[index].settings.gravity = value
            case .physicsDrag:      physicsConstraints[index].settings.drag = value
            default:                break
            }
        }
    }

    // MARK: Flag access

    func constraintFlag(_ id: UUID, _ property: AnimationTrackProperty) -> Bool? {
        guard let c = ikConstraints.first(where: { $0.id == id }) else { return nil }
        switch property {
        case .ikBendPositive: return c.bendPositive
        case .ikStretch:      return c.stretch
        case .ikCompress:     return c.compress
        default:              return nil
        }
    }

    mutating func setConstraintFlag(_ id: UUID, _ property: AnimationTrackProperty, _ value: Bool) {
        guard let index = ikConstraints.firstIndex(where: { $0.id == id }) else { return }
        switch property {
        case .ikBendPositive: ikConstraints[index].bendPositive = value
        case .ikStretch:      ikConstraints[index].stretch = value
        case .ikCompress:     ikConstraints[index].compress = value
        default:              break
        }
    }

    // MARK: Vector access

    func constraintVector(_ id: UUID, _ property: AnimationTrackProperty) -> SIMD2<Float>? {
        guard property == .physicsWind,
              let c = physicsConstraints.first(where: { $0.id == id }) else { return nil }
        return c.settings.wind
    }

    mutating func setConstraintVector(_ id: UUID, _ property: AnimationTrackProperty, _ value: SIMD2<Float>) {
        guard property == .physicsWind,
              let index = physicsConstraints.firstIndex(where: { $0.id == id }) else { return }
        physicsConstraints[index].settings.wind = value
    }

    // MARK: Setup snapshots

    /// Capture the current authored values of every animatable property of a
    /// constraint, so animation can restore them when a track is removed or the
    /// playhead sits outside the keyed range.
    func captureConstraintSetupValues(_ id: UUID) -> ConstraintSetupValues {
        var out = ConstraintSetupValues()
        for property in animatableProperties(forConstraint: id) {
            switch property.valueKind {
            case .scalar:
                if let value = constraintScalar(id, property) { out.set(property, scalar: value) }
            case .flag:
                if let value = constraintFlag(id, property) { out.set(property, flag: value) }
            case .vector2:
                if let value = constraintVector(id, property) { out.set(property, vector: value) }
            case .deform, .drawOrder, .event, .attachment:
                break
            }
        }
        return out
    }

    /// Write a whole setup snapshot back onto a constraint. Used when the
    /// playhead leaves an animated range and when undo restores a scene.
    mutating func applyConstraintSetupValues(_ id: UUID, _ values: ConstraintSetupValues) {
        for property in animatableProperties(forConstraint: id) {
            switch property.valueKind {
            case .scalar:
                if let value = values.scalar(property) { setConstraintScalar(id, property, value) }
            case .flag:
                if let value = values.flag(property) { setConstraintFlag(id, property, value) }
            case .vector2:
                if let value = values.vector(property) { setConstraintVector(id, property, value) }
            case .deform, .drawOrder, .event, .attachment:
                break
            }
        }
    }
}

extension AnimationTrackProperty {
    /// Clamp a raw value into the property's legal range. Applied on every write
    /// path, animated or manual, so an over-shooting Bézier curve can never push
    /// a mix outside 0…1 and destabilise the solver.
    func clamped(_ value: Float) -> Float {
        guard let range = valueRange else { return value }
        if value.isNaN { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// A sensible neutral value used when a property has no setup record yet.
    var neutralValue: Float {
        switch self {
        case .constraintMix,
             .transformRotateMix, .transformTranslateMix, .transformScaleMix, .transformShearMix,
             .pathPositionMix, .pathRotateMix:
            return 1
        case .physicsMass:
            return 1
        case .physicsDamping:
            return 0.88
        default:
            return 0
        }
    }
}
