import SwiftUI
import simd

/// The one place UltraMesh's colours are defined.
///
/// There were 117 hand-written `Color(white:)` and `Color(red:green:blue:)`
/// literals spread across the views, which is why the same surface could be
/// three slightly different greys depending on which file drew it. A palette
/// this specific has to live in one place or "identical to the mockup" is not
/// something that can be kept true past the first edit.
///
/// Values are read from the approved light mockup.
enum UM {

    // MARK: - Surfaces

    /// Behind everything: the gap the panels float on.
    static let appBackground = Color.um(light: 0xE9EDFE, dark: 0x0F1011)
    /// Toolbar and the left/right panels.
    static let surface = Color.um(light: 0xD9E0FC, dark: 0x1A1B1E)
    /// Segmented-control tracks and other inset wells on `surface`.
    static let surfaceInset = Color.um(light: 0xC9D4F7, dark: 0x121315)
    /// Raised chips: the light half of a segmented control, entry fields.
    static let surfaceRaised = Color.um(light: 0xE7EBFD, dark: 0x26282C)

    /// Hairline between the toolbar and the work area.
    static let hairline = Color.umPair(light: 0x1E2A4A, lightOpacity: 0.08, dark: 0xFFFFFF, darkOpacity: 0.10)

    // MARK: - Ink

    static let textPrimary = Color.um(light: 0x1E2A4A, dark: 0xE9EAEC)
    // Opacities are the lowest that clear WCAG on the LIGHTEST surface in the
    // palette; the values that came straight off the mockup measured 3.2:1 and
    // 1.9:1, which is unreadable body text and a hint that is barely there.
    // verify_theme_contrast.py holds the line.
    static let textSecondary = Color.umPair(light: 0x1E2A4A, lightOpacity: 0.71, dark: 0xE9EAEC, darkOpacity: 0.72)
    static let textMuted = Color.umPair(light: 0x1E2A4A, lightOpacity: 0.55, dark: 0xE9EAEC, darkOpacity: 0.52)

    // The IK constraint's mark in the tree: a two-bone chain.
    /// The bone from the root to the elbow. The reference's near-black, taken
    /// to the panel's own ink so the tree reads as one drawing.
    static let ikGlyphUpper = Color.um(light: 0x1E2A4A, dark: 0xD6D8DC)
    /// The bone from the elbow to the tip. The reference's red, deep enough to
    /// clear 3:1 on the panel — the canvas red is brighter and lands at 3.04,
    /// which is fine over artwork and thin against a pale panel.
    static let ikGlyphLower = Color.um(light: 0xC8202B, dark: 0xFF6B72)

    /// Text sitting on `accent`.
    ///
    /// Ink, not white. White on the mockup's periwinkle measures 2.44:1 — the
    /// selected tab would be the least readable text in the window. The mockup
    /// is itself of two minds here: its active "Pose" pill has white text while
    /// its active "Properties" pill has dark text. Ink keeps the accent colour
    /// exactly as drawn and reads at 5.80:1; matching the white would have
    /// meant darkening the accent to #6674A3, which is a different colour.
    static let textOnAccent = Color.um(light: 0x1E2A4A, dark: 0x0E0F11)

    // MARK: - Accents

    /// Selected segment, primary buttons.
    static let accent = Color.um(light: 0x8FA4E6, dark: 0x7E8FD0)
    /// Small emphasised pills over the canvas, e.g. Hide Bones.
    static let accentStrong = Color.um(light: 0x7B93E8, dark: 0x8FA0E4)
    /// Round icon buttons in the toolbar.
    static let accentSoft = Color.um(light: 0xB9C6F2, dark: 0x3A3F52)
    /// The canvas mode pill, recovered from the drawing the same way as the
    /// panel below it: composited #CBD4F2 over the light checker square and
    /// #C4CDEE over the dark one.
    static let canvasPillFill = Color.umPair(light: 0xBBC7EE, lightOpacity: 0.72, dark: 0x2A2D36, darkOpacity: 0.82)
    /// The lit mode's disc, and the ink of the ones that are not lit.
    ///
    /// One violet for whichever mode is active, as drawn — not the mode's own
    /// accent. The drawing marks the selected mode by position, not by hue.
    static let canvasPillActive = Color.um(light: 0x8D80E6, dark: 0x9B8FF0)
    static let canvasPillInk = Color.um(light: 0x39415F, dark: 0xD8DAE2)
    /// The wordmark glyph.
    static let brandMagenta = Color.um(light: 0xC94FBF, dark: 0xE36FD8)

    // MARK: - Canvas overlays
    //
    // This used to say the canvas was a dark checkerboard, so panels over it
    // inverted to dark chrome with light text. The canvas is light now, and the
    // last view drawing that dark set was rewritten; its five entries are gone
    // rather than left as a palette nothing paints with.
    //
    // What floats over the canvas has the opposite problem: the checkerboard is
    // the same family of light blue-greys as the chrome, so a panel needs a
    // tone that clears BOTH checker squares, not just the light one.

    /// The transform readout at the bottom-left of the canvas.
    ///
    /// Read off the approved drawing, tone for tone, at the author's explicit
    /// instruction after an earlier pass substituted deeper values for contrast.
    /// How each number was recovered, so it can be checked rather than trusted:
    /// the drawing shows the panel crossing a checker seam, so the same fill is
    /// visible composited over both squares. Two composites and two known
    /// backgrounds give the fill and its alpha exactly —
    /// `alpha = 1 - d(composite) / d(checker)`.
    ///
    /// Composites to #989BBF over the dark checker square and #A1A2C2 over the
    /// light one, which is what the drawing shows. The fill and its alpha are
    /// the exact solution of those two readings, not a value chosen to look
    /// close to them.
    ///
    /// THESE TONES DO NOT MEET WCAG, and that is a decision, not an oversight.
    /// On the composited panel the resting label measures 2.44:1, the navy axis
    /// letter 2.36:1 and the amber active row 1.89:1.
    /// `verify_coord_panel_look.py` prints every one of those ratios on each
    /// run and pins these values to the drawing, so the trade is recorded and
    /// visible rather than silently re-litigated.
    static let coordPanelFill = Color.umPair(light: 0x7273A1, lightOpacity: 0.64, dark: 0x2E3040, darkOpacity: 0.78)
    static let coordPanelBorder  = Color.white.opacity(0.14)

    /// The value slots: a white wash over the panel, +21 on each composite,
    /// which is white at 0.20.
    static let coordFieldTint    = Color.white.opacity(0.20)
    static let coordFieldBorder  = Color.white.opacity(0.35)

    /// The row label and the axis letter as drawn: a soft light grey for the
    /// resting rows, and a medium navy inside the slots. The number is the one
    /// bright thing on the panel, and it is pure white.
    static let coordLabelInk     = Color.white.opacity(0.70)
    static let coordLetterInk = Color.um(light: 0x31497B, dark: 0xA9BCE6)
    static let coordValueInk     = Color.white

    /// The active row's colour.
    ///
    /// The drawing lights Rotate, in a warmer gold than the timeline's — that
    /// exact tone is used here. The other three have no reference in the
    /// drawing, so they stay the timeline's own channel colours, which is where
    /// the artist already knows them from.
    static func coordAccent(for property: AnimationTrackProperty) -> Color {
        switch property {
        case .rotate:    return Color(hex: 0xF7B72A)   // the drawing's amber
        case .translate: return channelTranslate
        case .scale:     return channelScale
        case .shear:     return channelShear
        default:         return coordLabelInk
        }
    }

    // MARK: - Semantic accents kept from the dark theme

    static let boneAccent = Color.um(light: 0xE04AC7, dark: 0xF06AD4)
    /// The hierarchy's bone glyph: white body, purple contour. A deeper purple
    /// than `boneAccent` on purpose — the contour is roughly one pixel wide at
    /// the sizes the tree draws it, and a lighter one dissolves into the panel.
    /// What a bone with no binding is drawn in, wherever a colour is required.
    /// A neutral, so an unbound bone never looks like it is painted.
    static let unboundBone = SIMD4<Float>(0.55, 0.58, 0.66, 1)

    // MARK: - Inspector panels
    //
    // The Mesh and Weights drawings are one family: the same card, the same
    // segmented control, the same slider ramp, the same tick. Those tones live
    // here under one name and both panels read them, because two constants for
    // one drawn colour is how two panels that are supposed to match stop
    // matching. What is genuinely unique to one panel is named for that panel,
    // below.
    //
    // Every value is read off the drawing. Nothing is substituted for contrast,
    // and nothing carries alpha: the drawings show no background through any of
    // these surfaces, so a translucent value would be indistinguishable on
    // screen from the solid it composites to — and a solid is a colour a
    // contrast check can measure rather than one whose readability depends on
    // what happens to be behind it. What each pair measures is printed by
    // verify_mesh_inspector_look.py and verify_weights_inspector_look.py on
    // every run rather than corrected.

    static let inspectorCard = Color.um(light: 0xE2EBFD, dark: 0x1F2124)
    static let inspectorCardBorder = Color.um(light: 0xCBD9F4, dark: 0x303338)
    static let inspectorRule = Color.um(light: 0xC6D3EE, dark: 0x2B2E33)
    static let inspectorHeadingInk = Color.um(light: 0x5C6683, dark: 0x9AA0AE)

    /// The segmented control. Add is the lit one in both drawings.
    static let inspectorSegmentTrack = Color.um(light: 0xE7EDFC, dark: 0x191A1D)
    static let inspectorSegmentActive = Color.um(light: 0xB5E7BE, dark: 0x2E5B3A)
    static let inspectorSegmentActiveInk = Color.um(light: 0x1F5B2E, dark: 0xBFEFC9)
    static let inspectorSegmentInk = Color.um(light: 0x98A3BE, dark: 0x8B92A0)

    /// The pale action pills. Two tones, alternating down the grid.
    static let inspectorPillFill = Color.um(light: 0xECF2FF, dark: 0x24262A)
    static let inspectorPillAltFill = Color.um(light: 0xE8EFFE, dark: 0x202226)
    static let inspectorPillInk = Color.um(light: 0x232C4A, dark: 0xE4E6EA)
    static let inspectorResetInk = Color.um(light: 0xC0202B, dark: 0xFF7078)

    /// The sliders. The fill DARKENS to the right, which is the drawings' own
    /// idea and worth keeping: the knob ends up on the deepest part of the ramp
    /// wherever it is dragged, rather than the palest.
    static let inspectorSliderTrack = Color.um(light: 0xC8D3FA, dark: 0x2C2F35)
    static let inspectorRampStart = Color.um(light: 0x8B97E8, dark: 0x7E8AD4)
    static let inspectorRampEnd = Color.um(light: 0x4E5B76, dark: 0xC6CBD8)
    static let inspectorKnobFill = Color.um(light: 0xEAF6FF, dark: 0xE8EDF4)

    static let inspectorLabelInk = Color.um(light: 0x2B3450, dark: 0xD5D8DE)
    static let inspectorValueInk = Color.um(light: 0x3A4360, dark: 0xC2C6CE)
    /// The greyed note beside a label — "Interior density", "per vertex".
    static let inspectorNoteInk = Color.um(light: 0x8792AD, dark: 0x8A909C)
    /// The footer line — "Vertices", "Bound bones".
    static let inspectorFooterInk = Color.um(light: 0x6B7797, dark: 0x9298A4)

    /// The tick, in both drawings: a blue ring with a blue check inside it.
    static let inspectorCheckFill = Color.um(light: 0xDDEBFB, dark: 0x1E2833)
    static let inspectorCheckBorder = Color.um(light: 0x4A93DB, dark: 0x5AA6EE)
    static let inspectorCheckMark = Color.um(light: 0x2F6FA8, dark: 0x7FC0FF)

    // MARK: - Weights panel only

    static let weightsBindFill = Color.um(light: 0xC6D2F8, dark: 0x2B3050)
    static let weightsBindInk = Color.um(light: 0x5B2BD9, dark: 0xB39BFF)
    static let weightsBindBonesFill = Color.um(light: 0xDCE8FE, dark: 0x1F2530)
    static let weightsBindBonesInk = Color.um(light: 0x22304F, dark: 0xD6DCE8)
    static let weightsAutoStart = Color.um(light: 0xD7CBF7, dark: 0x3A3054)
    static let weightsAutoEnd = Color.um(light: 0xF5CEE3, dark: 0x4A2E40)
    static let weightsAutoInk = Color.um(light: 0x2B2350, dark: 0xE7E2F5)
    static let weightsSmoothInk = Color.um(light: 0x8E10C4, dark: 0xD07BF0)
    static let weightsListFill = Color.um(light: 0xE5EDFD, dark: 0x1B1D21)
    static let weightsRowHighlight = Color.um(light: 0xCEDFF9, dark: 0x2A303C)
    static let weightsBoneInk = Color.um(light: 0x111827, dark: 0xE8EAEE)
    static let weightsTrashFill = Color.um(light: 0xD4E4FA, dark: 0x262A31)
    static let weightsTrashInk = Color.um(light: 0x3A4257, dark: 0xC9CDD6)

    // MARK: - Mesh panel only

    /// Auto-Mesh, the one pill in that drawing that is not one of the two pale
    /// tones: a soft lavender, flat rather than the Weights panel's ramp.
    static let meshAutoFill = Color.um(light: 0xDFD8F6, dark: 0x332C4A)

    /// The bone and image glyphs are the same value in both appearances, at the
    /// author's request — the day drawing is the one to keep — and the drawing
    /// is built in a way that lets them be.
    ///
    /// Both are a contour with an OPAQUE BODY under it: the ring is drawn, then
    /// white paper, then the hue at 22% on top of the paper. The paper is why
    /// `BoneGlyph` puts it there at all — "so the body is the hue over paper
    /// rather than the hue over whatever row stripe it lands on" — and it makes
    /// the glyph independent of what is behind it. On the day panel the paper
    /// reads at 1.31:1; on the night panel at 17.2:1. Bright, but a sticker on
    /// a dark panel is what a sticker on a dark panel looks like, and the
    /// drawing inside it is unchanged: contour on paper stays at 6.8:1 either
    /// way, because neither of those two colours moved.
    ///
    /// A night pass was tried here and taken back out. Darkening the paper to
    /// hold the day's 1.3:1 lift did keep the glyph off the panel, but the body
    /// is the bone's own colour at 22% OVER that paper — so darkening the paper
    /// drained the hue out of every bone in the tree, which is the one thing
    /// the glyph exists to show.
    ///
    /// This does NOT generalise to the rest of the family. `meshGlyphInk` and
    /// the two IK bones are strokes with no paper under them, so their ink sits
    /// on the panel and has to move with it; their day values measure 2.46:1
    /// and 1.22:1 on the night panel. `verify_theme_night.py` splits the two
    /// groups and holds each to its own rule.
    static let boneGlyphFill   = Color.um(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let boneGlyphBorder = Color.um(light: 0x6D3BC4, dark: 0x6D3BC4)
    /// The image glyph wears the same treatment in fuchsia. `boneAccent`
    /// darkened to 67%, which lands within 0.001 of the bone contour's
    /// luminance — so neither glyph is the fainter one in a row of both — and
    /// 48 degrees of hue away from it, which is what keeps them two colours
    /// rather than two shades. It carries paper too, and passes through for the
    /// same reason: splitting the pair would put a white-paper bone next to a
    /// dark-paper image in the same row.
    static let imageGlyphFill   = Color.um(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let imageGlyphBorder = Color.um(light: 0x963285, dark: 0x963285)
    /// The mesh glyph is a wireframe with no body, so it is one colour. The
    /// most saturated amber there is at the bone contour's luminance — 137
    /// degrees from the purple and 89 from the fuchsia, at L 0.100 against
    /// their 0.104, so all three glyphs carry the same weight in a row.
    static let meshGlyphInk = Color.um(light: 0x7C5000, dark: 0xE0A93A)
    /// The same ball on the canvas mode button, where it is the Mesh mode's own
    /// mark rather than one of three kinds in a list — so it takes the blue-
    /// violet the button row is built from instead of the hierarchy's amber.
    /// 4.87:1 on the pill it sits on.
    static let meshGlyphCanvasInk = Color.um(light: 0x4B3FD0, dark: 0x8E85F0)
    static let weightAccent = Color.um(light: 0x9E66EB, dark: 0xB98AF2)
    static let poseAccent = Color.um(light: 0x8FA4E6, dark: 0x7E8FD0)
    // The two mode marks are the ONLY colours that pass through night
    // unchanged, and it is deliberate: cyan means Editor and amber means
    // Animator, and a mark that means something is not a surface tint. Both
    // are saturated enough to hold against the day panels and the night ones,
    // so darkening them would cost the recognition and buy nothing.
    // `verify_theme_night.py` pins this list, so a colour that ends up with
    // the same value on both sides BY ACCIDENT is caught rather than joining
    // them quietly.
    static let editorAccent = Color.um(light: 0x5CE0FF, dark: 0x5CE0FF)
    static let animatorAccent = Color.um(light: 0xFF942E, dark: 0xFF942E)
    // MARK: - Transform channels
    //
    // One channel, one colour, everywhere it appears: the coordinate panel on
    // the canvas, the timeline's rows, the diamonds those rows draw, and the
    // key button. These four were written out three separate times — and one of
    // those copies chose between them by switching on a row's DISPLAY TITLE,
    // which a rename would have broken silently.
    static let channelTranslate = Color(red: 0.30, green: 0.62, blue: 0.95)
    static let channelRotate    = Color(red: 0.95, green: 0.82, blue: 0.30)
    static let channelScale     = Color(red: 0.95, green: 0.55, blue: 0.25)
    static let channelShear     = Color(red: 0.72, green: 0.50, blue: 0.92)

    /// The colour of a transform channel, or nil for a property that is not one.
    static func channelColor(for property: AnimationTrackProperty) -> Color? {
        switch property {
        case .translate: return channelTranslate
        case .rotate:    return channelRotate
        case .scale:     return channelScale
        case .shear:     return channelShear
        default:         return nil
        }
    }

    static let dangerAccent = Color.um(light: 0xE05B54, dark: 0xF0736C)
    static let okAccent = Color.um(light: 0x3FC47A, dark: 0x4FD98C)

    // MARK: - Canvas
    //
    // SIMD rather than Color: the canvas is drawn by Metal, and having the
    // renderer carry its own private copies of these is how the checkerboard
    // and the theme drifted apart in the first place.

    /// The transparency checkerboard. Near-white and a pastel blue-grey, so it
    /// reads as "nothing here" without competing with the artwork. The old
    /// mid-greys (0.38 / 0.44) were left over from the dark theme and made the
    /// canvas the heaviest thing on screen.
    static let checkerLight = SIMD3<Float>(0.957, 0.965, 0.992)   // #F4F6FD
    static let checkerDark  = SIMD3<Float>(0.859, 0.886, 0.949)   // #DBE2F2

    /// The checkerboard at night.
    ///
    /// Two greys rather than the day palette's pale blues, at the same
    /// contrast ratio between the squares — the board's job is to read as
    /// transparency without competing with the artwork, and that is a
    /// relationship between the two squares, not an absolute lightness.
    ///
    /// Separate constants rather than a dynamic colour because these go to a
    /// Metal shader as raw floats. A `Color` resolves itself at draw time
    /// against the view's appearance; a `SIMD3<Float>` cannot, so the RENDERER
    /// asks the view which appearance it is drawing in. See
    /// `MetalRenderer.checkerColours(for:)`.
    static let checkerLightNight = SIMD3<Float>(0.180, 0.184, 0.196)   // #2E2F32
    static let checkerDarkNight  = SIMD3<Float>(0.145, 0.149, 0.161)   // #252629

    // Everything drawn over the canvas had been tuned for a dark background.
    // On the light checkerboard five of seven measured under 2.5:1 and would
    // have effectively vanished, so each was darkened while keeping its hue —
    // the colours still mean what they meant. verify_theme_contrast.py holds
    // the line.

    /// The selected sprite's rim, drawn along its alpha silhouette.
    ///
    /// Brighter and more magenta than `canvasMesh`, which is deliberate: both
    /// are fuchsia, and they can be on screen together in Mesh Edit, so the one
    /// that means "this is selected" has to be the louder of the two.
    static let canvasSelect      = SIMD3<Float>(0.93, 0.11, 0.70)

    /// The pre-selection rim: what a click would select right now.
    ///
    /// Quiet on purpose — it follows the cursor, so anything with presence
    /// would strobe across the canvas. It is the only canvas mark that does
    /// NOT clear 3:1 against the light checker square, and it is exempt for a
    /// reason rather than by oversight: it is drawn INSIDE a sprite's
    /// silhouette, so it never touches the checkerboard, and it is always
    /// drawn over its own `contourInk` contour, which is what makes a pale
    /// mark legible on pale artwork. `verify_selection_outline.py` checks the
    /// contour instead of the ratio.
    static let canvasPreselect   = SIMD3<Float>(0.80, 0.81, 0.84)

    // Scene editor view. Not the shot's colours — the set is looked at from
    // outside, the way a stage is, and it needs a ground that is plainly "not
    // part of the picture". The reference uses a flat pale cyan for exactly
    // that reason: nothing in a finished frame is that colour.
    /// The void the set floats in while flying.
    /// The ground the set is flown over.
    ///
    /// Was a pale cyan, taken from the reference images. A tinted ground is a
    /// ground every colour on the set is judged against, and a middle grey is
    /// the standard working answer: dark contours and bright inks both read on
    /// it, where the cyan gave the dark ones plenty and the bright ones almost
    /// nothing.
    static let sceneVoid         = SIMD3<Float>(0.404, 0.404, 0.412)
    /// The shot camera's frustum and frame.
    static let sceneFrustum      = SIMD3<Float>(0.98, 0.84, 0.12)
    /// A card's outline and handles when it is not selected. Quiet on purpose:
    /// there is one of these per layer and they must not compete with the art.
    static let sceneCardHandle   = SIMD3<Float>(0.52, 0.55, 0.86)
    /// The selected card. Same fuchsia as the rig canvas's selection, so "this
    /// one" means the same thing in both modes.
    static let sceneCardSelected = SIMD3<Float>(0.93, 0.11, 0.70)

    /// Mesh outline, edges and vertex markers.
    static let canvasMesh        = SIMD3<Float>(0.85, 0.12, 0.66)
    /// Hover highlight.
    static let canvasHover       = SIMD3<Float>(0.02, 0.60, 0.48)
    /// Create-mode preview.
    static let canvasPreview     = SIMD3<Float>(0.02, 0.58, 0.18)

    // The rotate gizmo, redrawn from the reference: a needle, a pivot ring and
    // a dotted track.
    //
    /// The needle. The reference's red exactly — #F82327 — which needed no
    /// adjustment: it already measures 3.70:1 on the light checker square and
    /// 3.07:1 on the dark one.
    static let gizmoRotateNeedle = SIMD3<Float>(0.973, 0.137, 0.153)
    /// The pivot ring, its nub and the track's dots. A bright yellow.
    ///
    /// It cannot be made to clear 3:1 on the light checker square, and no
    /// yellow can: yellow IS bright, and darkened until it cleared the bar it
    /// measures #A88D00, which is olive. So it is not darkened. The mark is
    /// made to read the way the mesh nodes already are — a near-opaque dark
    /// contour under it, which holds its edge on a light square, a dark
    /// square, and over artwork of any colour including yellow. The fill stays
    /// bright, which is the whole point of it.
    static let gizmoRotateAccent  = SIMD3<Float>(1.000, 0.816, 0.102)
    /// The contour under every part of the gizmo.
    ///
    /// Under the needle as well as the ring. The needle is red and artwork is
    /// often red — a red spike over a red sprite is a spike you cannot see, and
    /// a contour makes every part of the gizmo independent of what is behind
    /// it rather than only the parts that happen to need it today.
    static let gizmoRotateContour = SIMD3<Float>(0.090, 0.078, 0.039)

    // The two axes, shared by Translate, Scale and Shear. X and Y, in the
    // convention every 2D tool uses — but stated here rather than written into
    // each builder, which is how the three ended up with three different reds.
    /// The X axis.
    static let gizmoAxisX = SIMD3<Float>(0.973, 0.137, 0.153)
    /// The Y axis. Darkened from a pure green until it clears 3:1 on both
    /// checker squares, like everything else drawn over this canvas.
    static let gizmoAxisY = SIMD3<Float>(0.081, 0.580, 0.242)

    static let boneFill          = SIMD3<Float>(0.22, 0.26, 0.38)
    static let boneOutline       = SIMD3<Float>(0.12, 0.16, 0.28)
    static let bonePreviewFill   = SIMD3<Float>(0.30, 0.34, 0.46)
    static let bonePreviewLine   = SIMD3<Float>(0.20, 0.24, 0.36)
    static let boneRootDot       = SIMD3<Float>(0.12, 0.16, 0.28)
    static let boneRootRing      = SIMD3<Float>(0.30, 0.34, 0.46)
    /// A vertex with no bone influence, in the weight overlay.
    static let weightUnassigned  = SIMD3<Float>(0.35, 0.39, 0.50)

    // Bind-mode signal colours, pastel like the bone palette. They still mean
    // stop / ready / done, and their contours come from `contourInk` so a
    // butter yellow reads as well as a mint green.
    static let bindUnbindPeach = SIMD3<Float>(0.98, 0.72, 0.55)
    /// Honey rather than butter: a pale yellow at 55 % barely tints a
    /// near-white canvas (1.06:1) and the state reads as no state at all.
    static let bindReadyButter = SIMD3<Float>(0.97, 0.85, 0.48)
    static let bindBoundMint   = SIMD3<Float>(0.62, 0.92, 0.74)

    // MARK: - Geometry

    /// Darkens a colour to a fixed luminance, keeping its hue.
    ///
    /// This is what makes a pastel palette workable on a light canvas. A fill
    /// can be as pale as it likes as long as its contour is readable, and a
    /// contour derived by a flat multiplier is not: pastel yellow at 65 % is
    /// still pale, pastel blue at 65 % is already dark, so the same rule gives
    /// wildly different contrast depending on hue.
    ///
    /// Scaling toward black preserves hue exactly — it is a scalar on all three
    /// channels — and binary-searching the scale for a luminance target gives
    /// every hue the same contrast against the canvas. Measured across the
    /// first 24 bone colours: 3.14:1 for all of them.
    ///
    /// The default target puts a contour just past 3:1 on `checkerLight`.
    static func contourInk(for colour: SIMD3<Float>, targetLuminance: Float = 0.26) -> SIMD3<Float> {
        func relativeLuminance(_ c: SIMD3<Float>) -> Float {
            func channel(_ v: Float) -> Float {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.x) + 0.7152 * channel(c.y) + 0.0722 * channel(c.z)
        }

        guard relativeLuminance(colour) > targetLuminance else { return colour }

        var low: Float = 0
        var high: Float = 1
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if relativeLuminance(colour * mid) > targetLuminance { high = mid } else { low = mid }
        }
        return colour * low
    }

    //
    // The mockup uses fully-rounded pills for controls and a soft radius for
    // panels; naming them keeps the two from drifting into each other.

    static let pillRadius: CGFloat   = 999
    static let panelRadius: CGFloat  = 14
    static let controlRadius: CGFloat = 10
}

extension Color {
    /// `Color(hex: 0xD9E0FC)` — the palette above is transcribed from the
    /// mockup in hex, and converting each one to three decimals by hand is how
    /// a value ends up subtly wrong.
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue:  Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
