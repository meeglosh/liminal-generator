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

/// Shared native adaptation of transitions.dev's quick response and soft
/// ease-out: tactile compression on touch, with no delay to the action.
private struct CTAPressFeedback: ViewModifier {
    let isPressed: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .shadow(color: tint.opacity(isPressed ? 0.25 : 0), radius: 6)
            .scaleEffect(isPressed && !reduceMotion ? 0.99 : 1)
            .offset(y: isPressed && !reduceMotion ? 2 : 0)
            .animation(reduceMotion ? nil : (isPressed
                ? .easeOut(duration: 0.10)
                : .timingCurve(0.22, 1, 0.36, 1, duration: 0.25)), value: isPressed)
    }
}

/// Thick-bottom-border button that depresses and illuminates on press.
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
            .background(background.overlay(tint.opacity(configuration.isPressed ? 0.07 : 0)))
            .overlay(Rectangle().stroke(borderColor, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(bottomBorderColor)
                    .frame(height: configuration.isPressed ? 0 : LiminalMetrics.deckButtonBorderWidth)
            }
            .modifier(CTAPressFeedback(isPressed: configuration.isPressed, tint: tint))
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
                Image(systemName: "dice")
                    .accessibilityHidden(true)
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
            .background(Color.liminalErrorContainer.overlay(Color.liminalError.opacity(configuration.isPressed ? 0.12 : 0)))
            .overlay(Rectangle().stroke(Color.liminalError, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(height: configuration.isPressed ? 0 : LiminalMetrics.deckButtonBorderWidth)
            }
            .modifier(CTAPressFeedback(isPressed: configuration.isPressed, tint: .liminalError))
    }
}

// MARK: - Analog fader slider

/// Blocky rectangular-thumb slider with CRT-green fill and sharp corners.
struct LiminalSlider: View {
    @Binding var value: Float // 0...1
    var trackHeight: CGFloat = 4
    var thumbSize: CGSize = CGSize(width: 12, height: 22)
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15)) { thumb in
                        thumb
                            .foregroundStyle(isDragging ? Color.liminalPrimary : Color.liminalCRTGreenDim)
                            .shadow(color: Color.liminalCRTGreenDim.opacity(isDragging ? 0.55 : 0), radius: 5)
                    }
                    .overlay(Rectangle().stroke(Color.liminalSurfaceContainerLowest, lineWidth: 1))
                    .offset(x: thumbX)
            }
            .frame(height: max(trackHeight, thumbSize.height), alignment: .center)
            // A plain SwiftUI `DragGesture`, once its `minimumDistance` is
            // exceeded, has already unconditionally "recognized" at the
            // UIKit level -- there's no SwiftUI API to retroactively fail it
            // from inside `onChanged`. Since a ScrollView's own pan
            // recognizer is, by default, required to fail *before* the
            // ScrollView itself is allowed to begin, a DragGesture whose
            // `onChanged` merely "ignores" vertical movement still holds
            // that lock silently for the gesture's whole lifetime -- it
            // recognizes, just does nothing -- which blocks scrolling
            // exactly as before. `DirectionalDragOverlay` below is a thin
            // UIKit `UIPanGestureRecognizer` subclass that actively
            // transitions itself to `.failed` (from `.possible`, before it
            // has ever recognized) the moment a touch reads as vertical,
            // which is the correct/only way to hand it back to the
            // ancestor ScrollView mid-gesture.
            .overlay(
                DirectionalDragOverlay(onHorizontalDrag: { fraction in
                    value = Float(fraction)
                }, onEditingChanged: { editing in
                    isDragging = editing
                })
            )
            // Exposes the current value for both VoiceOver and UI-test
            // verification (e.g. the vertical-drag-does-not-move-the-slider
            // regression test reads this before/after) without changing the
            // element's accessibility kind/traits, so `app.otherElements[...]`
            // lookups in existing tests keep matching exactly as before.
            .accessibilityValue("\(Int((clamped * 100).rounded()))")
            // Fader geometry must never inherit a surrounding panel animation.
            .transaction { $0.animation = nil }
        }
        .frame(height: thumbSize.height)
    }
}

/// Transparent gesture-only overlay used by `LiminalSlider`: recognizes a
/// drag only once it reads as clearly horizontal (`|dx| > |dy|` once the
/// touch has moved enough to classify), reporting the touch's x-fraction
/// (0...1 of the view's width) on every recognized update. A vertical/
/// diagonal-ish touch is failed early instead, releasing it to whatever
/// ancestor gesture (the page's ScrollView) would otherwise handle it.
private struct DirectionalDragOverlay: UIViewRepresentable {
    var onHorizontalDrag: (CGFloat) -> Void
    var onEditingChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = DirectionalPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onHorizontalDrag = onHorizontalDrag
        context.coordinator.onEditingChanged = onEditingChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHorizontalDrag: onHorizontalDrag, onEditingChanged: onEditingChanged)
    }

    final class Coordinator: NSObject {
        var onHorizontalDrag: (CGFloat) -> Void
        var onEditingChanged: (Bool) -> Void

        init(onHorizontalDrag: @escaping (CGFloat) -> Void, onEditingChanged: @escaping (Bool) -> Void) {
            self.onHorizontalDrag = onHorizontalDrag
            self.onEditingChanged = onEditingChanged
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .ended, .cancelled, .failed:
                onEditingChanged(false)
                return
            case .began:
                onEditingChanged(true)
            default: break
            }
            guard let view = recognizer.view, view.bounds.width > 0 else { return }
            switch recognizer.state {
            case .began, .changed:
                let x = recognizer.location(in: view).x
                onHorizontalDrag(min(max(0, x / view.bounds.width), 1))
            default:
                break
            }
        }
    }
}

/// Fails itself (transitioning `.possible -> .failed`, before ever
/// recognizing) the moment a touch's movement reads as more vertical than
/// horizontal. Direction is decided once per touch sequence, the first time
/// movement exceeds `directionThreshold` in either axis, then latched for
/// the rest of the gesture -- matching `LiminalSlider`'s "decide once, on
/// first movement" contract.
private final class DirectionalPanGestureRecognizer: UIPanGestureRecognizer {
    private let directionThreshold: CGFloat = 12
    private var startLocation: CGPoint = .zero
    private var isHorizontal: Bool?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        isHorizontal = nil
        if let touch = touches.first, let view {
            startLocation = touch.location(in: view)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else {
            super.touchesMoved(touches, with: event)
            return
        }

        if isHorizontal == nil {
            let loc = touch.location(in: view)
            let dx = loc.x - startLocation.x
            let dy = loc.y - startLocation.y
            guard max(abs(dx), abs(dy)) >= directionThreshold else { return }
            if abs(dx) > abs(dy) {
                isHorizontal = true
            } else {
                isHorizontal = false
                state = .failed
                return
            }
        }

        guard isHorizontal == true else { return }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        isHorizontal = nil
        startLocation = .zero
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.liminalSurfaceContainerHighest)
                    .overlay(
                        Rectangle().stroke(isOn ? Color.liminalCRTGreenDim : Color.liminalOutlineVariant, lineWidth: 1)
                    )
                Rectangle()
                    .fill(isOn ? Color.liminalCRTGreenDim : Color.liminalOnSurfaceVariant)
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.liminalCRTGreenDim.opacity(isOn ? 0.35 : 0), radius: 3)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
                    .padding(3)
                    .offset(x: isOn ? 20 : 0)
                    .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.12), value: isOn)
            }
            .frame(width: 44, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
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

    var fillsWidth: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.spaceMono(size: 10))
            .tracking(1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundColor(isSelected ? .liminalOnPrimary : .liminalOnSurfaceVariant)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
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
            LiminalChip(text: text, isSelected: isSelected, fillsWidth: true)
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

// MARK: - Clipped accordion body

/// Native adaptation of transitions.dev's accordion: reveal a top-anchored
/// body by changing its clipped height, never translating it across the header.
struct LiminalAccordionBody<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .padding(.top, LiminalMetrics.stackMedium)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(isExpanded ? 1 : 0)
            .frame(height: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.25), value: isExpanded)
    }
}
