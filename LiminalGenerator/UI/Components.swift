//
//  Components.swift
//  LiminalGenerator
//
//  Shared "analog hardware" UI components used across MainView, transcribed
//  from img/.../liminal_analog/DESIGN.md: deck-style buttons, blocky analog
//  sliders, a sharp-cornered toggle, tape-spine card chrome, and the
//  persistent low-opacity scanline overlay.
//

import SwiftUI
import UIKit

// MARK: - Deck button (tape-transport style)

/// Thick-bottom-border button that "depresses" on press: the border
/// disappears and the label shifts down by 1px, per DESIGN.md.
struct DeckButtonStyle: ButtonStyle {
    var tint: Color = .liminalCRTGreenDim
    var background: Color = .liminalSurfaceContainerHighest
    var borderColor: Color = .liminalOutline
    var bottomBorderColor: Color = .liminalSurfaceContainerLowest

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.spaceMono(size: 12, weight: .bold))
            .tracking(2)
            .foregroundColor(tint)
            .padding(.vertical, LiminalMetrics.stackMedium)
            .frame(maxWidth: .infinity)
            .background(background)
            .overlay(Rectangle().stroke(borderColor, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(bottomBorderColor)
                    .frame(height: configuration.isPressed ? 0 : LiminalMetrics.deckButtonBorderWidth)
            }
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// "⚄ GENERATE MELODY" / "⚄ GENERATE BEAT" style deck button with haptic tap.
struct DiceDeckButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 8) {
                Text("\u{2684}")
                Text(title.uppercased())
            }
        }
        .buttonStyle(DeckButtonStyle())
    }
}

/// Full-width "RENDER & SHARE" bar in the alert-red palette.
struct RenderBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.spaceMono(size: 18, weight: .bold))
            .tracking(1)
            .foregroundColor(.liminalOnErrorContainer)
            .padding(.vertical, LiminalMetrics.stackMedium)
            .frame(maxWidth: .infinity)
            .background(Color.liminalErrorContainer)
            .overlay(Rectangle().stroke(Color.liminalError, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(height: configuration.isPressed ? 0 : LiminalMetrics.deckButtonBorderWidth)
            }
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Analog fader slider

/// Blocky rectangular-thumb slider with CRT-green fill and sharp corners.
struct LiminalSlider: View {
    @Binding var value: Float // 0...1
    var trackHeight: CGFloat = 4
    var thumbSize: CGSize = CGSize(width: 12, height: 22)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = min(max(value, 0), 1)
            let thumbX = min(max(CGFloat(clamped) * w - thumbSize.width / 2, 0), w - thumbSize.width)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.liminalSurfaceContainerHigh)
                    .frame(height: trackHeight)
                Rectangle()
                    .fill(Color.liminalCRTGreenDim)
                    .frame(width: max(0, CGFloat(clamped) * w), height: trackHeight)
                Rectangle()
                    .fill(Color.liminalCRTGreenDim)
                    .overlay(Rectangle().stroke(Color.liminalSurfaceContainerLowest, lineWidth: 1))
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .offset(x: thumbX)
            }
            .frame(height: max(trackHeight, thumbSize.height), alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = min(max(0, drag.location.x), w)
                        value = Float(x / w)
                    }
            )
        }
        .frame(height: thumbSize.height)
    }
}

/// A slider row with a left label + right sub-label above it, and endpoint
/// readouts flanking the track (matches GLOBAL ENV / DRUMS LEVEL rows).
struct LiminalSliderRow: View {
    let label: String
    let subLabel: String?
    let leftEndpoint: String
    let rightEndpoint: String
    @Binding var value: Float
    /// Optional UI-test hook forwarded to the inner `LiminalSlider`'s
    /// accessibility identifier (this component is reused for SPACE, AGE,
    /// and DRUMS LEVEL, so each call site needs its own identifier).
    var sliderAccessibilityIdentifier: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline) {
                Text(label.uppercased())
                    .font(.spaceMono(size: 12))
                    .tracking(1)
                    .foregroundColor(.liminalCRTGreenDim)
                if let subLabel {
                    Spacer()
                    Text(subLabel.uppercased())
                        .font(.spaceMono(size: 10))
                        .tracking(1)
                        .foregroundColor(.liminalOnSurfaceVariant)
                }
            }
            HStack(spacing: LiminalMetrics.stackMedium) {
                Text(leftEndpoint)
                    .font(.spaceMono(size: 10))
                    .foregroundColor(.liminalOnSurfaceVariant)
                LiminalSlider(value: $value)
                    .accessibilityIdentifier(sliderAccessibilityIdentifier ?? "")
                Text(rightEndpoint)
                    .font(.spaceMono(size: 10))
                    .foregroundColor(.liminalOnSurfaceVariant)
            }
        }
    }
}

// MARK: - Sharp-cornered toggle

struct LiminalToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(Color.liminalSurfaceContainerHighest)
                    .overlay(
                        Rectangle().stroke(isOn ? Color.liminalCRTGreenDim : Color.liminalOutlineVariant, lineWidth: 1)
                    )
                Rectangle()
                    .fill(isOn ? Color.liminalCRTGreenDim : Color.liminalOnSurfaceVariant)
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .frame(width: 44, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Card chrome ("tape spine" label)

/// Sharp-edged card container with a labeled "tape spine" header, per
/// DESIGN.md ("Cards (VCR Static)").
struct LiminalCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LiminalMetrics.stackMedium) {
            content()
        }
        .padding(LiminalMetrics.stackMedium)
        .padding(.top, LiminalMetrics.spacingUnit)
        .background(Color.liminalSurfaceContainer)
        .overlay(Rectangle().stroke(Color.liminalOutlineVariant, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Text(title.uppercased())
                .font(.spaceMono(size: 12))
                .tracking(3)
                .foregroundColor(.liminalOnSurfaceVariant)
                .padding(.horizontal, 6)
                .background(Color.liminalBackground)
                .offset(x: 12, y: -9)
        }
    }
}

// MARK: - Thin outlined chip

struct LiminalChip: View {
    let text: String
    /// When true, renders filled with CRT green (selected state) instead of
    /// the default thin-outline/dim-text look. Purely visual — this struct
    /// stays a static label; `LiminalSelectableChip` below wraps it in a
    /// tappable button for single-select rows like the waveform picker.
    var isSelected: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.spaceMono(size: 10))
            .tracking(1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundColor(isSelected ? .liminalOnPrimary : .liminalOnSurfaceVariant)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.liminalCRTGreenDim : Color.clear)
            .overlay(Rectangle().stroke(isSelected ? Color.liminalCRTGreenDim : Color.liminalOutlineVariant, lineWidth: 1))
    }
}

/// Tappable single-select chip built on `LiminalChip`: taps fire a light
/// haptic (matching `LiminalToggle`'s pattern) then `action`. Used for the
/// SYNTH card's waveform row (SINE/TRIANGLE/SQUARE/SAW).
struct LiminalSelectableChip: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            LiminalChip(text: text, isSelected: isSelected)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Persistent scanline / noise overlay

/// Subtle full-screen scanline texture layered above the entire UI
/// (2-3% opacity per DESIGN.md "Elevation & Depth").
struct ScanlineOverlay: View {
    var opacity: Double = 0.05

    var body: some View {
        Canvas { context, size in
            let lineSpacing: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(.black))
                y += lineSpacing
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
