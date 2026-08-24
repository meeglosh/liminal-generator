//
//  SplashView.swift
//  LiminalGenerator
//
//  In-app splash (~2s) shown after launch, before MainView. Matches
//  img/splash_screen/screen.png: dark static/noise texture, green camcorder
//  glyph, glitch chromatic-aberration wordmark, and two green mono status
//  lines ("ESTABLISHING ANALOG CONNECTION..." / "BUFFERING SIGNAL |||").
//

import SwiftUI

/// Static noise texture drawn once (cheap: no per-frame animation needed —
/// it's a still grainy backdrop, matching the mockup's low-opacity static
/// image).
private struct StaticNoiseTexture: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    if Bool.random() {
                        let shade = Double.random(in: 0.0...0.5)
                        context.fill(
                            Path(CGRect(x: x, y: y, width: cell, height: cell)),
                            with: .color(Color.white.opacity(shade))
                        )
                    }
                    x += cell
                }
                y += cell
            }
        }
        .opacity(0.03)
        .allowsHitTesting(false)
    }
}

/// Chromatic-aberration "glitch" wordmark: red/cyan ghost copies offset
/// behind the primary text, per DESIGN.md ".chromatic-aberration".
private struct GlitchWordmark: View {
    let text: String

    var body: some View {
        ZStack {
            Text(text)
                .foregroundColor(.red.opacity(0.65))
                .offset(x: -2)
            Text(text)
                .foregroundColor(.cyan.opacity(0.65))
                .offset(x: 2)
            Text(text)
                .foregroundColor(.liminalPrimary)
        }
        .font(.spaceMono(size: 28, weight: .bold))
        .tracking(-0.5)
        .multilineTextAlignment(.center)
    }
}

struct SplashView: View {
    @State private var bufferStep = 0
    @State private var pulse = false
    private let bufferTimer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()
    private let maxBufferSteps = 10

    var body: some View {
        ZStack {
            Color.liminalSurfaceContainerLowest.ignoresSafeArea()
            StaticNoiseTexture().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.liminalCRTGreenDim.opacity(0.35))
                        .frame(width: 108, height: 108)
                        .blur(radius: 24)
                    Image("SplashIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.liminalCRTGreenDim.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: .liminalCRTGreenDim.opacity(0.9), radius: 14)
                }
                .padding(.bottom, LiminalMetrics.stackLarge)

                GlitchWordmark(text: "LIMINAL GENERATOR")

                Spacer()
                Spacer()

                VStack(spacing: LiminalMetrics.spacingUnit) {
                    Text("ESTABLISHING ANALOG CONNECTION...")
                        .font(.spaceMono(size: 10))
                        .tracking(2)
                        .foregroundColor(.liminalCRTGreenDim)
                        .opacity(pulse ? 1.0 : 0.5)

                    Text("BUFFERING SIGNAL \(bufferBar)")
                        .font(.spaceMono(size: 10))
                        .tracking(2)
                        .foregroundColor(.liminalPrimary.opacity(0.7))
                }
                .padding(.bottom, LiminalMetrics.stackLarge * 1.5)
            }
            .padding(.horizontal, LiminalMetrics.marginMobile)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onReceive(bufferTimer) { _ in
            bufferStep = (bufferStep + 1) % (maxBufferSteps + 1)
        }
    }

    private var bufferBar: String {
        let filled = String(repeating: "|", count: bufferStep)
        let empty = String(repeating: " ", count: maxBufferSteps - bufferStep)
        return "[\(filled)\(empty)]"
    }
}

#Preview {
    SplashView()
}
