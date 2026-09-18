//
//  VHSImageCard.swift
//  LiminalGenerator
//
//  The swipeable, VHS-filtered image card at the top of MainView: live
//  Metal shader look (VHSShader.metal), VCR OSD overlay (timestamp / REC /
//  SP / PLAY-PAUSE), and paged left/right swiping through ImageLibrary with
//  wraparound.
//

import SwiftUI
import UIKit

// MARK: - Splash-dismissed environment signal
//
// `LiminalGeneratorApp` shows `SplashView()` for a fixed hold + fade before
// `MainView` (and this file's `VHSOSDOverlay`) is actually visible to the
// user. The first-launch PLAY typewriter reveal below needs to know exactly
// when that's actually happened so it can start the reveal then — NOT after
// a second, independently-started guess at the same duration. Two separate
// fixed-delay timers that are assumed to land in sync but each start
// counting from their own view's mount time (app launch vs. this file's own
// deep-nested view finally laying out, which is not the same instant,
// especially under load — first-use Metal shader pipeline compilation in
// particular can push this view's mount meaningfully later) is exactly the
// kind of drift that produces a flaky race rather than a wrong-every-time
// bug. Routing the actual dismissal moment through the environment removes
// that second guess entirely: this view always starts its reveal keyed to
// the real event, however long the app took to get there. Defaults to
// `true` so anything constructed outside `LiminalGeneratorApp`'s own
// environment (previews, and any future test harness that mounts this view
// directly) behaves as "already dismissed" rather than waiting forever.
private struct SplashDismissedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var splashDismissed: Bool {
        get { self[SplashDismissedKey.self] }
        set { self[SplashDismissedKey.self] = newValue }
    }
}

// MARK: - Shader modifier

private extension View {
    /// Applies the live VHS look shader. `energy` softens the effect a
    /// touch when paused (tracking jitter is scaled by it) so the still
    /// frame doesn't roll while nothing is "playing".
    func vhsFilter(time: Double, size: CGSize, energy: Float) -> some View {
        let shader = ShaderLibrary.vhsEffect(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(time)),
            .float(energy)
        )
        return self.layerEffect(shader, maxSampleOffset: CGSize(width: size.width * 0.06 + 12, height: 0))
    }
}

private struct VHSFilteredImage: View {
    let assetName: String
    let isActive: Bool
    let isPlaying: Bool
    let timeOrigin: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || reduceMotion || scenePhase != .active)) { context in
            GeometryReader { geo in
                // Subtract in Double before converting to the shader Float. All
                // carousel pages share this origin so swipes preserve the phase.
                let t = reduceMotion ? 0 : max(0, context.date.timeIntervalSince(timeOrigin))
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .vhsFilter(time: t, size: geo.size, energy: isPlaying ? 1.0 : 0.35)
                    // `.layerEffect`'s `maxSampleOffset` (see `vhsFilter` above)
                    // makes SwiftUI render this page's output *wider* than its
                    // own frame, so it has real pixels to sample when the
                    // shader's horizontal taps reach near an edge. Left
                    // un-clipped, that overhang paints on top of whichever
                    // neighboring page is drawn after this one in the paging
                    // `ZStack` below -- in practice the index+1 page's left
                    // overhang lands on the current page's right edge (the
                    // reverse, an index-1 page's right overhang, is hidden
                    // because the current page is drawn on top of it). Clip
                    // back to this page's own frame *after* the filter so the
                    // overhang is discarded instead of bleeding onto a
                    // neighbor; the in-bounds pixels are unaffected since the
                    // shader already clamps its own sample positions.
                    .clipped()
            }
        }
    }
}

// MARK: - OSD overlay

private struct VHSOSDOverlay: View {
    let timestamp: VHSTimestamp
    let isPlaying: Bool
    /// Whether the timestamp / REC dot / SP indicator should be visible.
    /// False while the CRT is off or mid switch-on/off animation — per the
    /// product spec those three elements are hidden any time the picture
    /// itself isn't the settled "on" state, leaving PLAY as the only thing
    /// on a dead screen. The PLAY/PAUSE control itself is NOT gated by this
    /// — it must always be present, off-screen or on.
    let showInfo: Bool
    let onTogglePlay: () -> Void
    /// True while the PLAY control should pulse/glow to draw the eye — i.e.
    /// the user hasn't tapped play yet this session and nothing is playing.
    /// Owned by `VHSImageCard` (this overlay is torn down and rebuilt every
    /// time the card pages to a new image), so the attract *phase* below is
    /// local, disposable animation state that simply restarts on rebuild.
    let attractPlay: Bool
    /// Mirrors `VHSImageCard`'s own `hasTappedPlay` (see its doc comment) —
    /// before the user's first tap this session the PLAY control sits
    /// centered and 2x size; after that first tap it lives bottom-left at
    /// normal size permanently, independent of `isPlaying`/`showInfo`. This
    /// overlay only ever gets rebuilt (losing its local `@State`) via a page
    /// swipe, and swiping is disallowed until the screen is on, which can't
    /// happen before the first tap — so the single glide from center to the
    /// corner always plays out within one overlay instance.
    let hasTappedPlay: Bool
    /// The card's own on-screen size (it's square, so width == height) —
    /// needed to compute the centered placement and the offset back to the
    /// permanent bottom-left corner. See `centeringOffset`.
    let cardSize: CGSize

    @State private var blinkOn = true
    @State private var attractPulse = false
    /// The PLAY/PAUSE control's own laid-out size (pre-scale), measured via
    /// `onGeometryChange` so `centeringOffset` can reproduce exactly where
    /// the bottom-left `.padding(12)` placement would anchor it, without
    /// hardcoding label-width assumptions.
    @State private var buttonSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.splashDismissed) private var splashDismissed
    private let blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: First-launch PLAY typewriter intro
    //
    // Product ask: on first launch, in the centered/2x pre-tap state, "PLAY"
    // types itself onto the screen character-by-character with a blinking
    // cursor, like a terminal/VCR OSD reveal — the same visual language as
    // RenderScreen's "ENCODING ANALOG SIGNAL▮" header and its `▮` cursor.
    // Runs exactly once per launch (guarded by `introStarted`), only in the
    // pre-tap state (`!hasTappedPlay`); after the first tap `playLabel`
    // below stops consulting any of this entirely, so it can never replay
    // when the screen later goes dark on pause or on image paging.

    /// Characters of "PLAY" revealed so far (0...4). Stays 0 until the
    /// intro kicks off, jumps straight to 4 for `reduceMotion`.
    @State private var introTypedCount = 0
    /// True only while characters are actively being revealed — gates the
    /// blinking cursor. Chosen (per product direction) to vanish once
    /// typing completes rather than linger: the attract pulse/glow takes
    /// over immediately after, and running both at once made them fight
    /// for attention.
    @State private var introTyping = false
    /// True once the intro has finished (or was skipped) — the attract
    /// pulse is held off until this flips, so it never starts mid-type.
    @State private var introComplete = false
    /// Guards `runIntroTypingIfNeeded()` against being kicked off twice.
    @State private var introStarted = false
    /// ~60–90ms/char reads as deliberate, typed intent without feeling
    /// slow; 70ms lands the whole 4-character "PLAY" reveal in well under
    /// half a second once it starts.
    private let introMsPerChar: Double = 70

    var body: some View {
        ZStack {
            // Top-left: timestamp + REC
            VStack(alignment: .leading, spacing: 2) {
                osdText(timestamp.dateText)
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(recOpacity)
                    osdText("REC", color: .liminalError)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .opacity(showInfo ? 1 : 0)

            // Top-right: SP
            osdText("SP")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
                .opacity(showInfo ? 1 : 0)

            // Bottom-left (permanent home once `hasTappedPlay`): PLAY / PAUSE
            // control. Before the first tap it instead sits centered at 2x
            // size (see `centeringOffset`/`attractScale`) — an obvious first
            // target on the dead screen. While `attractPlay` is true it also
            // throbs — a gentle scale pulse plus a swelling CRT-green glow —
            // to pull the eye to it before the user has ever pressed it.
            Button(action: onTogglePlay) {
                HStack(spacing: 6) {
                    playLabel
                    Text(isPlaying ? "\u{275A}\u{275A}" : "\u{25B6}")
                        .font(.spaceMono(size: 14, weight: .bold))
                        .foregroundColor(.liminalPrimary)
                        .shadow(color: .liminalCRTGreenDim.opacity(0.8), radius: 3)
                        .contentTransition(.identity)
                }
                // The label/glyph must flip the instant `isPlaying` changes,
                // never crossfade. Without this, the label's text-content
                // change rides along on whatever ambient animation happens
                // to be active on the same view-update transaction (e.g. the
                // CRT switch-on/off `withAnimation` in `powerOn`/`powerOff`
                // over in `VHSImageCard`), which SwiftUI renders as PLAY and
                // PAUSE briefly superimposed — looks like a rendering glitch.
                // `.animation(nil, value:)` scoped to just this HStack kills
                // that without touching the attract pulse/glow (those are
                // driven by their own explicit `withAnimation` calls in
                // `updateAttractAnimation()`, applied outside this HStack on
                // the Button itself, so they're unaffected).
                .animation(nil, value: isPlaying)
                // Measured pre-scale (the HStack's own layout size never
                // changes under `.scaleEffect`), so `centeringOffset` below
                // can compute the exact bottom-left anchor point this button
                // would occupy under its permanent `.padding(12)` placement.
                // The label is always "PLAY" pre-tap (can't be playing
                // without having tapped play first), so this is stable
                // throughout the only period it's actually used.
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { buttonSize = $0 }
            }
            .buttonStyle(.plain)
            .scaleEffect(attractScale)
            // Slides the button from its permanent bottom-left anchor to the
            // card's center pre-tap; zero (no-op) once `hasTappedPlay`, so
            // the permanent placement below is untouched by this modifier
            // for the rest of the session.
            .offset(centeringOffset)
            .shadow(color: .liminalCRTGreenDim.opacity(attractGlowOpacity), radius: attractGlowRadius)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(12)
            // Independent of the visual reveal: VoiceOver must always hear
            // the full "Play"/"Pause" label, never a half-typed string —
            // the typewriter intro is a purely visual effect. Overrides
            // whatever label SwiftUI would otherwise synthesize from the
            // (possibly partial, pre-tap) text inside the button. Applied
            // AFTER `.scaleEffect`/`.offset`/`.frame`/`.padding` (not before,
            // where it originally sat) -- an accessibility modifier placed
            // before those geometry effects anchors the element's
            // accessibility/hit-test frame to the PRE-transform layout rect
            // instead of the actual on-screen (2x, centered) one during the
            // pre-tap state, which silently swallowed the whole first tap:
            // XCUITest reported a successful synthesized tap (no "not
            // hittable" error) at a screen point that was never actually
            // over the button, so `onTogglePlay` never fired and
            // `isPlaying` never flipped. Keeping this after the geometry
            // modifiers, alongside `.accessibilityIdentifier` below (which
            // was already correctly positioned here and is why existence /
            // initial-hittable checks passed), keeps the accessible frame
            // matched to the real hit target through the whole reveal.
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("playPauseButton")
        }
        .onReceive(blinkTimer) { _ in
            blinkOn.toggle()
        }
        .onAppear { updateAttractAnimation() }
        .onChange(of: attractPlay) { updateAttractAnimation() }
        .onChange(of: introComplete) { updateAttractAnimation() }
        .task { await runIntroTypingIfNeeded() }
        // Covers the case where this view mounts (and its `.task` above
        // runs) BEFORE the splash has actually cleared: `runIntroTypingIfNeeded`
        // returns early without setting `introStarted` when `splashDismissed`
        // is still false, so this fires the real attempt the moment it
        // flips true. See `splashDismissed`'s doc comment for why this
        // replaces a hardcoded guess at the splash's duration.
        .onChange(of: splashDismissed) {
            if splashDismissed {
                Task { await runIntroTypingIfNeeded() }
            }
        }
    }

    /// The PLAY/PAUSE text itself. Before the first tap it's driven by the
    /// typewriter intro (always "PLAY" — can't be playing without having
    /// tapped play first); after that first tap it's the plain, instant-flip
    /// label this button always used pre-typewriter, and none of the intro
    /// state below is consulted again for the rest of the session.
    @ViewBuilder
    private var playLabel: some View {
        if hasTappedPlay {
            osdText(isPlaying ? "PAUSE" : "PLAY", size: 16, weight: .bold)
                .contentTransition(.identity)
        } else {
            typewriterPlayLabel
        }
    }

    /// Renders "PLAY" revealed character-by-character with a blinking `▮`
    /// cursor — the same glyph RenderScreen's "ENCODING ANALOG SIGNAL▮"
    /// header uses. A zero-opacity copy of the FULL "PLAY▮" string sits
    /// underneath at all times to reserve the final width/height from the
    /// very first frame: this is what keeps `onGeometryChange` above (and
    /// therefore the hit target `centeringOffset` positions) stable through
    /// the whole reveal instead of growing character-by-character. That
    /// placeholder is `.accessibilityHidden` so it can never surface as a
    /// second, duplicate accessibility element alongside the button's own
    /// `.accessibilityLabel`.
    private var typewriterPlayLabel: some View {
        let revealed = String("PLAY".prefix(introTypedCount))
        let cursor = introTyping ? (blinkOn ? "\u{25AE}" : " ") : " "
        return ZStack(alignment: .leading) {
            osdText("PLAY\u{25AE}", size: 16, weight: .bold)
                .opacity(0)
                .accessibilityHidden(true)
            osdText(revealed + cursor, size: 16, weight: .bold)
        }
    }

    /// Kicks off the first-launch PLAY typewriter intro exactly once — see
    /// the intro `@State` properties' doc comments above, and
    /// `splashDismissed`'s, for the full reasoning. Called both from this
    /// view's own `.task` (covers the common case: the splash is already
    /// dismissed by the time this mounts, or Reduce Motion applies and the
    /// splash doesn't matter at all) and from `.onChange(of: splashDismissed)`
    /// (covers this view mounting first and the splash clearing later) — safe
    /// to call from both/either since `introStarted` guards the real work to
    /// a single run, and a call that finds the splash still up simply returns
    /// without setting that guard so the later call can proceed.
    private func runIntroTypingIfNeeded() async {
        guard !introStarted else { return }

        guard !reduceMotion, !hasTappedPlay else {
            // Reduce Motion: skip the typing entirely, per spec — the
            // finished label appears immediately, independent of the splash.
            // (An already-tapped launch is defensive; can't actually happen
            // this early, but if it somehow did, the plain `playLabel`
            // branch above would already be in control and none of this
            // would be visible regardless.)
            introStarted = true
            introTypedCount = 4
            introComplete = true
            return
        }

        guard splashDismissed else { return }
        introStarted = true

        introTyping = true
        for count in 1...4 {
            try? await Task.sleep(for: .milliseconds(introMsPerChar))
            // Bail immediately if the user tapped PLAY mid-reveal: `playLabel`
            // switches to the plain instant label the moment `hasTappedPlay`
            // flips, so there's nothing left here to finish revealing.
            guard !Task.isCancelled, !hasTappedPlay else { return }
            introTypedCount = count
        }
        introTyping = false
        introComplete = true
    }

    /// Starts (or cleanly cancels) the forever-repeating attract throb. Using
    /// `withAnimation` to flip `attractPulse` true kicks off the repeating
    /// animation; flipping it back to false with a short plain animation
    /// cancels the repeat and settles the button back to its resting state
    /// instead of leaving it stuck mid-pulse. Held off entirely until the
    /// typewriter intro has finished (or was skipped) — see `introComplete`
    /// — so the pulse/glow never starts mid-type and fights the reveal for
    /// attention.
    private func updateAttractAnimation() {
        guard attractPlay, reduceMotion || introComplete else {
            withAnimation(.easeInOut(duration: 0.2)) {
                attractPulse = false
            }
            return
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            attractPulse = true
        }
    }

    /// Base 2.0 pre-tap / 1.0 permanent, times the attract pulse's small
    /// multiplicative bump on top (pulse only ever runs pre-tap, since
    /// `attractPlay` implies `!hasTappedPlay`).
    private var attractScale: CGFloat {
        let base: CGFloat = hasTappedPlay ? 1.0 : 2.0
        guard attractPlay, attractPulse, !reduceMotion else { return base }
        return base * 1.06
    }

    /// Slides the button from its permanent bottom-left anchor to the card's
    /// center. Reproduces where the `.frame(alignment: .bottomLeading)` +
    /// `.padding(12)` placement below would anchor the button (using the
    /// measured pre-scale `buttonSize`), then offsets from there to the
    /// card's center — so at `hasTappedPlay == true` this is exactly zero
    /// and the permanent placement is completely undisturbed.
    private var centeringOffset: CGSize {
        guard !hasTappedPlay, buttonSize != .zero, cardSize != .zero else { return .zero }
        let padding: CGFloat = 12
        let anchorX = padding + buttonSize.width / 2
        let anchorY = cardSize.height - padding - buttonSize.height / 2
        return CGSize(width: cardSize.width / 2 - anchorX, height: cardSize.height / 2 - anchorY)
    }

    // Glow constants are bumped up for the larger pre-tap button so the
    // glow still reads as proportionate to the control — this branch only
    // ever executes pre-tap (`attractPlay` implies `!hasTappedPlay`).
    private var attractGlowOpacity: Double {
        guard attractPlay else { return 0.0 }
        return attractPulse ? 0.9 : 0.25
    }

    private var attractGlowRadius: CGFloat {
        guard attractPlay else { return 0.0 }
        return attractPulse ? 15 : 5
    }

    private var recOpacity: Double {
        guard isPlaying else { return 0.35 }
        return blinkOn ? 1.0 : 0.2
    }

    private func osdText(_ text: String, color: Color = .liminalPrimary, size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.spaceMono(size: size, weight: weight))
            .tracking(1)
            .foregroundColor(color)
            .shadow(color: color.opacity(0.85), radius: 4)
            .shadow(color: .black.opacity(0.6), radius: 1, x: 1, y: 1)
    }
}

// MARK: - Swipeable card

struct VHSImageCard: View {
    @Binding var index: Int
    @Binding var timestamp: VHSTimestamp
    let isPlaying: Bool
    /// Mirrors `isScreenOn` below (declared here, alongside the other
    /// caller-supplied parameters, rather than down by its sibling power-
    /// state properties) purely so the synthesized memberwise initializer's
    /// parameter order matches how call sites read: index, timestamp,
    /// isPlaying, isScreenOn, onTogglePlay. See `isScreenOn`'s own doc
    /// comment near the rest of the CRT power state for what it means.
    @Binding var isScreenOn: Bool
    let onTogglePlay: () -> Void

    @State private var timeOrigin = Date()
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// Once true, the PLAY button's attract pulse/glow stops for good this
    /// session. Lives here (not on `VHSOSDOverlay`) because that overlay is
    /// re-created every time the card pages to a new image — this state must
    /// survive a swipe.
    @State private var hasTappedPlay = false
    /// True while the released drag is animating (spring/ease) to its
    /// settled position — keeps the neighbor strips live (shader running,
    /// not clipped away) through the settle, and is the guard that lets the
    /// index-swap-at-full-offset trick land as a single seamless frame.
    @State private var isSettling = false

    // MARK: CRT power state
    //
    // The card is a "dead CRT" (fully black, PLAY is the only thing on it)
    // whenever nothing is playing, and switches on/off around `isPlaying`.
    // These are plain @State (not an enum) because each drives an
    // independently-animatable knob of the switch-on/off sequence, and the
    // sequence is expressed as a chain of `withAnimation(_:completion:)`
    // calls (iOS 17) rather than a state machine — see `powerOn`/`powerOff`.

    // `isScreenOn` itself is declared up top with the other caller-supplied
    // parameters (see its doc comment there) — true only once the switch-on
    // sequence has fully settled: OSD info (timestamp/REC/SP) is visible and
    // swiping is allowed. False the instant switch-off begins (OSD/swipe cut
    // immediately; the picture keeps animating closed for a moment after).
    // This is the only place that writes it, in `powerOn`/`powerOff`.

    /// Gates whether the three image pages' `TimelineView`s tick at all
    /// (see `VHSFilteredImage`'s `isActive` → `paused:`). Set true at the
    /// *start* of switch-on (before the picture is visible) so the shader
    /// has already rendered a correct filtered frame by the time the bloom
    /// reveals it, and set false only at the very *end* of switch-off, once
    /// the picture is fully collapsed and invisible — this is what actually
    /// stops the 30fps shader work while the screen reads as off, rather
    /// than just covering it with a black rectangle.
    @State private var isImageStackActive = false
    /// Vertical extent of the picture, 0 = collapsed to nothing, 1 = full
    /// frame. Combined with the fact that the image pages sit on top of an
    /// opaque black backdrop, animating this from 0→1 IS the "line blooms
    /// vertically" effect for free (the shrunk image just doesn't cover the
    /// black behind it). Non-reduce-motion path only.
    @State private var screenScaleY: CGFloat = 0
    /// Plain crossfade opacity used ONLY under `accessibilityReduceMotion`,
    /// where the spec calls for skipping the line/bloom/collapse geometry
    /// entirely. `screenScaleY` is left at 1 in that path.
    @State private var imageOpacity: CGFloat = 0
    /// Horizontal extent (0...1) of the bright snap-open / collapse line.
    @State private var lineWidth: CGFloat = 0
    @State private var lineFlashOpacity: Double = 0
    /// Decaying horizontal jitter applied to the picture (not the OSD/button)
    /// during the post-bloom tracking-wobble beat of switch-on.
    @State private var trackingOffsetX: CGFloat = 0
    /// Horizontal overscan applied alongside `trackingOffsetX` during the
    /// wobble so the picture always overfills the frame at max displacement
    /// -- without it, shifting the image stack sideways uncovers the black
    /// `crtOffBackdrop` as a hard strip down the trailing edge (the backdrop
    /// is opaque and directly behind the picture with nothing else masking
    /// it). 1.0 = no zoom (rest state); bumped up in lockstep with each
    /// wobble step, back to 1.0 once the offset settles to 0. The margin
    /// only needs to cover `trackingOffsetX`'s max magnitude (9pt) plus a
    /// cushion -- 7% overscan clears that on any realistic card width
    /// (>=130pt) since the outer `.clipped()` on the GeometryReader content
    /// still bounds everything to the card's own frame.
    @State private var wobbleScale: CGFloat = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // `.aspectRatio` is applied to a flexible `Color.clear` rather than
        // directly to the `GeometryReader` below: `GeometryReader` reports a
        // degenerate ideal size (unlike `Color`, which reports one matching
        // whatever size it's proposed), which throws off `.aspectRatio`'s fit
        // math when composed directly on top of it -- a well-known SwiftUI
        // gotcha. Overlaying the real content keeps the geometry read exact.
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    let width = geo.size.width

                    // Both drag-neighbor visibility AND the CRT power state
                    // gate the shader/TimelineView work: while the screen is
                    // off (isImageStackActive == false) none of the three
                    // pages tick, regardless of drag state.
                    let neighborsActive = isImageStackActive && (isDragging || isSettling)

                    ZStack {
                        // Powered-off backdrop: opaque black with a very
                        // restrained sheen so it reads as a dead CRT rather
                        // than an empty box. Always present, static (no
                        // TimelineView, no per-frame cost) — it's simply
                        // painted over by the image pages once the screen is
                        // on, and revealed through the shrunk gaps while the
                        // picture is collapsed/collapsing.
                        crtOffBackdrop(width: width)

                        // The picture itself: the three paged shader views,
                        // wobbled and scaled as one unit for the switch-on/
                        // off animation. Scaling this group (rather than
                        // each page) keeps the existing per-page paging
                        // offsets untouched.
                        ZStack {
                            VHSFilteredImage(assetName: ImageLibrary[index - 1].assetName, isActive: neighborsActive, isPlaying: isPlaying, timeOrigin: timeOrigin)
                                .offset(x: -width + dragOffset)
                            VHSFilteredImage(assetName: ImageLibrary[index].assetName, isActive: isImageStackActive, isPlaying: isPlaying, timeOrigin: timeOrigin)
                                .offset(x: dragOffset)
                            VHSFilteredImage(assetName: ImageLibrary[index + 1].assetName, isActive: neighborsActive, isPlaying: isPlaying, timeOrigin: timeOrigin)
                                .offset(x: width + dragOffset)
                        }
                        .offset(x: reduceMotion ? 0 : trackingOffsetX)
                        // `wobbleScale` overscans horizontally in lockstep
                        // with `trackingOffsetX` so the wobble displaces the
                        // picture without ever uncovering `crtOffBackdrop`
                        // at the frame edge (see the property's doc comment).
                        .scaleEffect(x: reduceMotion ? 1 : wobbleScale, y: reduceMotion ? 1 : screenScaleY, anchor: .center)
                        .opacity(reduceMotion ? imageOpacity : 1)

                        // Bright snap-open / collapse line, independent of
                        // the picture's own scale so it can flash at full
                        // brightness for a beat before/after the bloom.
                        if !reduceMotion {
                            crtSwitchLine(width: width)
                        }

                        VHSOSDOverlay(
                            timestamp: timestamp,
                            isPlaying: isPlaying,
                            showInfo: isScreenOn,
                            onTogglePlay: {
                                // The very first tap of the session also
                                // glides PLAY from its centered/2x resting
                                // place to its permanent bottom-left home —
                                // timed to land alongside the CRT switch-on
                                // sequence below (`powerOn`, ~0.5s) so it
                                // reads as one event ("the CRT waking up"),
                                // not a widget sliding around independently.
                                // Every tap after this one is a no-op here:
                                // `hasTappedPlay` is already true, so this
                                // withAnimation wraps a state write that
                                // doesn't actually change anything.
                                if reduceMotion {
                                    hasTappedPlay = true
                                } else {
                                    withAnimation(.easeOut(duration: 0.5)) {
                                        hasTappedPlay = true
                                    }
                                }
                                onTogglePlay()
                            },
                            attractPlay: !hasTappedPlay && !isPlaying,
                            hasTappedPlay: hasTappedPlay,
                            cardSize: geo.size
                        )
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                // Screen off (or mid switch-on/off): dead —
                                // no paging, nothing visibly moves.
                                guard isScreenOn, !isSettling else { return }
                                isDragging = true
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                guard isScreenOn, !isSettling else { return }
                                isDragging = false
                                let threshold = width * 0.22
                                if value.translation.width < -threshold {
                                    settle(direction: 1, width: width)
                                } else if value.translation.width > threshold {
                                    settle(direction: -1, width: width)
                                } else {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                }
            )
            .background(Color.liminalSurfaceContainerLow)
            .overlay(Rectangle().stroke(Color.liminalOutlineVariant, lineWidth: 1))
            .clipped()
            .onAppear {
                // No animation on first mount: land directly in whatever
                // state `isPlaying` already says (normally off, since
                // nothing has played yet).
                isPlaying ? powerOn(animated: false) : powerOff(animated: false)
            }
            .onChange(of: isPlaying) { _, playing in
                playing ? powerOn(animated: true) : powerOff(animated: true)
            }
    }

    // MARK: - CRT switch-on / switch-off

    /// Reads as dark glass with a tube behind it, not an empty rectangle —
    /// deliberately restrained per the product spec ("a convincing dead
    /// screen, not a decorated one"). No animation, no TimelineView: this is
    /// the whole reason the off-state is cheap. Layers, back to front:
    /// a lifted, slightly warm grey-green base (never pure black) built
    /// from existing design-system tokens rather than a bespoke color, a
    /// broad low-contrast specular sheen standing in for a curved glass
    /// surface catching ambient light, a corner vignette for tube
    /// curvature, and a scattering of near-invisible static dust so the
    /// surface isn't a perfectly flat gradient.
    private func crtOffBackdrop(width: CGFloat) -> some View {
        ZStack {
            // Base glass tone. `liminalSurfaceContainerLowest` alone reads
            // as pure black on an OLED; tinting it faintly with the design
            // system's dark olive-green outline token lifts it just enough
            // to register as glass, and keeps the off-state cohesive with
            // the CRT-green palette instead of introducing a new color.
            Color.liminalSurfaceContainerLowest
            Color.liminalOutlineVariant.opacity(0.16)

            // Broad, soft specular sheen — a curved glass surface catching
            // ambient light from the upper-left. Large radius and a slow,
            // multi-stop falloff keep it diffuse; there is no hard edge
            // anywhere in this gradient.
            RadialGradient(
                colors: [
                    Color.liminalOutline.opacity(0.11),
                    Color.liminalOutline.opacity(0.045),
                    Color.liminalOutline.opacity(0.015),
                    .clear
                ],
                center: UnitPoint(x: 0.3, y: 0.2),
                startRadius: 0,
                endRadius: width * 0.95
            )

            // Vignette: darker into the corners, consistent with tube
            // curvature. Pure black (not tinted) so it reads as shadow/
            // depth rather than adding more color.
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.5)],
                center: .center,
                startRadius: width * 0.3,
                endRadius: width * 0.75
            )

            // Faint static phosphor dust: a handful of near-invisible
            // flecks. Seeded so the pattern is fixed rather than actual
            // per-frame noise — this is still a single static draw, not a
            // TimelineView, so it doesn't reintroduce per-frame cost.
            staticDust(width: width)
        }
    }

    /// A sparse scattering of near-invisible dust/phosphor flecks over the
    /// dead screen, using the same deterministic `SeededGenerator` the
    /// audio side uses for reproducible randomness (see
    /// `Audio/PatternGenerator.swift`) so the pattern is fixed rather than
    /// re-rolled (and thus visibly "twinkling") on every body re-evaluation.
    private func staticDust(width: CGFloat) -> some View {
        Canvas { context, size in
            var rng = SeededGenerator(seed: 1998)
            for _ in 0..<36 {
                let x = CGFloat.random(in: 0...size.width, using: &rng)
                let y = CGFloat.random(in: 0...size.height, using: &rng)
                let diameter = CGFloat.random(in: 0.4...1.1, using: &rng)
                let opacity = Double.random(in: 0.015...0.05, using: &rng)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
        .frame(width: width, height: width)
        .allowsHitTesting(false)
    }

    /// The bright horizontal line used for both the switch-on "snap open"
    /// beat and the switch-off "collapse" beat. `lineWidth` is the
    /// horizontal extent (0...1, scaled from center) and `lineFlashOpacity`
    /// its brightness; both are driven by `powerOn`/`powerOff`.
    private func crtSwitchLine(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.liminalPrimary)
            .frame(width: width, height: 3)
            .scaleEffect(x: lineWidth, y: 1, anchor: .center)
            .opacity(lineFlashOpacity)
            .shadow(color: .liminalPrimary.opacity(0.9), radius: 8)
            .allowsHitTesting(false)
    }

    /// Switch-on: line snaps open (~0.08s) → blooms vertically to fill the
    /// frame (~0.18s) → brief decaying tracking wobble (~0.25s) → OSD info
    /// (timestamp/REC/SP) fades in and swiping is re-enabled. ~0.5s total,
    /// matching the product spec. `animated: false` is used only for the
    /// initial mount, to land silently in the correct state.
    private func powerOn(animated: Bool) {
        // Start the shader ticking immediately (before anything is visible)
        // so by the time the bloom reveals the picture it's already a
        // correctly VHS-filtered frame, never a one-frame flash of raw
        // unfiltered content.
        isImageStackActive = true

        guard animated else {
            screenScaleY = 1
            imageOpacity = 1
            lineWidth = 0
            lineFlashOpacity = 0
            trackingOffsetX = 0
            wobbleScale = 1
            isScreenOn = true
            return
        }

        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) {
                imageOpacity = 1
            } completion: {
                isScreenOn = true
            }
            return
        }

        screenScaleY = 0
        lineWidth = 0
        lineFlashOpacity = 0
        trackingOffsetX = 0
        wobbleScale = 1

        withAnimation(.easeOut(duration: 0.08)) {
            lineWidth = 1
            lineFlashOpacity = 1
        } completion: {
            withAnimation(.easeOut(duration: 0.18)) {
                screenScaleY = 1
                lineFlashOpacity = 0
            } completion: {
                runTrackingWobble()
            }
        }
    }

    /// Chains a short, decaying sequence of horizontal offsets to read as
    /// tape-tracking instability settling down, then reveals the OSD.
    /// Expressed as a recursive chain of `withAnimation(_:completion:)`
    /// calls (iOS 17) rather than a Timer/Task.sleep sequence, matching the
    /// synchronous, allocation-free style the rest of the file uses for
    /// chained animations (see `settle(direction:width:)` below).
    private func runTrackingWobble() {
        // `scale` rides along with each `offset` so the picture always
        // overfills the frame at that step's displacement — see
        // `wobbleScale`'s doc comment. It decays back to 1.0 in step with
        // the offset decaying back to 0.
        let steps: [(offset: CGFloat, scale: CGFloat, duration: Double)] = [
            (9, 1.08, 0.08), (-5, 1.045, 0.07), (2, 1.02, 0.06), (0, 1.0, 0.04)
        ]
        stepTrackingWobble(steps, index: 0) {
            withAnimation(.easeOut(duration: 0.1)) {
                isScreenOn = true
            }
        }
    }

    private func stepTrackingWobble(_ steps: [(offset: CGFloat, scale: CGFloat, duration: Double)], index: Int, completion: @escaping () -> Void) {
        guard index < steps.count else {
            completion()
            return
        }
        withAnimation(.easeInOut(duration: steps[index].duration)) {
            trackingOffsetX = steps[index].offset
            wobbleScale = steps[index].scale
        } completion: {
            stepTrackingWobble(steps, index: index + 1, completion: completion)
        }
    }

    /// Switch-off: OSD/swipe cut immediately, then the picture collapses
    /// toward a horizontal line, shrinks to a center dot, and fades
    /// (~0.35s total) before the shader stops ticking.
    private func powerOff(animated: Bool) {
        // Cut OSD info and swiping immediately — the picture keeps
        // animating closed for a moment after, but the card already reads
        // as "off" from an interaction standpoint.
        isScreenOn = false

        guard animated else {
            screenScaleY = 0
            imageOpacity = 0
            lineWidth = 0
            lineFlashOpacity = 0
            trackingOffsetX = 0
            wobbleScale = 1
            isImageStackActive = false
            return
        }

        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) {
                imageOpacity = 0
            } completion: {
                isImageStackActive = false
            }
            return
        }

        trackingOffsetX = 0
        wobbleScale = 1
        withAnimation(.easeIn(duration: 0.15)) {
            screenScaleY = 0
            lineWidth = 1
            lineFlashOpacity = 1
        } completion: {
            // Line shrinks toward a center dot...
            withAnimation(.easeIn(duration: 0.1)) {
                lineWidth = 0.05
            } completion: {
                // ...and fades out.
                withAnimation(.easeOut(duration: 0.1)) {
                    lineFlashOpacity = 0
                } completion: {
                    lineWidth = 0
                    // Only now — picture fully collapsed and invisible —
                    // does the shader actually stop ticking.
                    isImageStackActive = false
                }
            }
        }
    }

    /// Animates the strip the rest of the way off-screen in the swipe's
    /// direction (continuing the finger's motion rather than snapping back),
    /// then — once that settle animation completes — instantly swaps `index`
    /// and resets `dragOffset` to 0 in the same frame. That swap is visually
    /// seamless: at the moment the animation lands, the neighbor that was
    /// sliding in (drawn at `±width + dragOffset`) is already sitting exactly
    /// at the strip's center, which is bit-for-bit where the new "current"
    /// image (offset 0) will be drawn the instant `index` updates. Haptic +
    /// timestamp regeneration fire immediately on release (once per
    /// COMPLETED swipe), not gated on the animation finishing.
    private func settle(direction: Int, width: CGFloat) {
        isSettling = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        timestamp = .random()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            dragOffset = direction > 0 ? -width : width
        } completion: {
            index += direction
            dragOffset = 0
            isSettling = false
        }
    }
}
