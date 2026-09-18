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

    @State private var blinkOn = true
    @State private var attractPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

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

            // Bottom-left: PLAY / PAUSE control. While `attractPlay` is true it
            // throbs — a gentle scale pulse plus a swelling CRT-green glow —
            // to pull the eye to it before the user has ever pressed it.
            Button(action: onTogglePlay) {
                HStack(spacing: 6) {
                    osdText(isPlaying ? "PAUSE" : "PLAY", size: 16, weight: .bold)
                        .contentTransition(.identity)
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
            }
            .buttonStyle(.plain)
            .scaleEffect(attractScale)
            .shadow(color: .liminalCRTGreenDim.opacity(attractGlowOpacity), radius: attractGlowRadius)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(12)
            .accessibilityIdentifier("playPauseButton")
        }
        .onReceive(blinkTimer) { _ in
            blinkOn.toggle()
        }
        .onAppear { updateAttractAnimation() }
        .onChange(of: attractPlay) { updateAttractAnimation() }
    }

    /// Starts (or cleanly cancels) the forever-repeating attract throb. Using
    /// `withAnimation` to flip `attractPulse` true kicks off the repeating
    /// animation; flipping it back to false with a short plain animation
    /// cancels the repeat and settles the button back to its resting state
    /// instead of leaving it stuck mid-pulse.
    private func updateAttractAnimation() {
        if attractPlay {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                attractPulse = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                attractPulse = false
            }
        }
    }

    private var attractScale: CGFloat {
        guard attractPlay, attractPulse, !reduceMotion else { return 1.0 }
        return 1.06
    }

    private var attractGlowOpacity: Double {
        guard attractPlay else { return 0.0 }
        return attractPulse ? 0.9 : 0.25
    }

    private var attractGlowRadius: CGFloat {
        guard attractPlay else { return 0.0 }
        return attractPulse ? 10 : 3
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

    /// True only once the switch-on sequence has fully settled: OSD info
    /// (timestamp/REC/SP) is visible and swiping is allowed. False the
    /// instant switch-off begins (OSD/swipe cut immediately; the picture
    /// keeps animating closed for a moment after).
    @State private var isScreenOn = false
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
                                hasTappedPlay = true
                                onTogglePlay()
                            },
                            attractPlay: !hasTappedPlay && !isPlaying
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

    /// A faint dark radial vignette plus a barely-there diagonal glass
    /// reflection — deliberately restrained per the product spec ("off",
    /// not "decorated"). No animation, no TimelineView: this is the whole
    /// reason the off-state is cheap.
    private func crtOffBackdrop(width: CGFloat) -> some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.white.opacity(0.05), Color.clear],
                center: .center,
                startRadius: 0,
                endRadius: width * 0.7
            )
            LinearGradient(
                colors: [Color.white.opacity(0.025), .clear, .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
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
