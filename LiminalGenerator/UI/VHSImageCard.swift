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
        return self.layerEffect(shader, maxSampleOffset: CGSize(width: 24, height: 0))
    }
}

private struct VHSFilteredImage: View {
    let assetName: String
    let isActive: Bool
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
            GeometryReader { geo in
                let t = context.date.timeIntervalSinceReferenceDate
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .vhsFilter(time: t, size: geo.size, energy: isPlaying ? 1.0 : 0.35)
            }
        }
    }
}

// MARK: - OSD overlay

private struct VHSOSDOverlay: View {
    let timestamp: VHSTimestamp
    let isPlaying: Bool
    let onTogglePlay: () -> Void

    @State private var blinkOn = true
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

            // Top-right: SP
            osdText("SP")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)

            // Bottom-left: PLAY / PAUSE control
            Button(action: onTogglePlay) {
                HStack(spacing: 6) {
                    osdText(isPlaying ? "PAUSE" : "PLAY", size: 16, weight: .bold)
                    Text(isPlaying ? "\u{275A}\u{275A}" : "\u{25B6}")
                        .font(.spaceMono(size: 14, weight: .bold))
                        .foregroundColor(.liminalPrimary)
                        .shadow(color: .liminalCRTGreenDim.opacity(0.8), radius: 3)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(12)
            .accessibilityIdentifier("playPauseButton")
        }
        .onReceive(blinkTimer) { _ in
            blinkOn.toggle()
        }
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

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// True while the released drag is animating (spring/ease) to its
    /// settled position — keeps the neighbor strips live (shader running,
    /// not clipped away) through the settle, and is the guard that lets the
    /// index-swap-at-full-offset trick land as a single seamless frame.
    @State private var isSettling = false

    private var currentImage: LiminalImage { ImageLibrary[index] }

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

                    let neighborsActive = isDragging || isSettling

                    ZStack {
                        VHSFilteredImage(assetName: ImageLibrary[index - 1].assetName, isActive: neighborsActive, isPlaying: isPlaying)
                            .offset(x: -width + dragOffset)
                        VHSFilteredImage(assetName: ImageLibrary[index].assetName, isActive: true, isPlaying: isPlaying)
                            .offset(x: dragOffset)
                        VHSFilteredImage(assetName: ImageLibrary[index + 1].assetName, isActive: neighborsActive, isPlaying: isPlaying)
                            .offset(x: width + dragOffset)

                        VHSOSDOverlay(timestamp: timestamp, isPlaying: isPlaying, onTogglePlay: onTogglePlay)
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard !isSettling else { return }
                                isDragging = true
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                guard !isSettling else { return }
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
