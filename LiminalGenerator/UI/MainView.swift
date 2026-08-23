//
//  MainView.swift
//  LiminalGenerator
//
//  Main screen: scrollable card stack over #131313 matching
//  img/stitch_liminal_space_generator/generator_player/screen.png — header,
//  VHS image card, SYNTH / GLOBAL ENV / DRUMS cards, and the RENDER & SHARE
//  bar. Owns the AudioEngineController for the app.
//

import SwiftUI

struct MainView: View {
    @StateObject private var engine = AudioEngineController()

    @State private var imageIndex = Int.random(in: 0..<ImageLibrary.count)
    @State private var timestamp = VHSTimestamp.random()
    @State private var showAbout = false
    @State private var showRender = false

    var body: some View {
        ZStack {
            Color.liminalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: LiminalMetrics.stackLarge) {
                        imageSection

                        LiminalCard(title: "SYNTH") {
                            synthCardContent
                        }

                        LiminalCard(title: "BASSLINE") {
                            bassCardContent
                        }

                        LiminalCard(title: "GLOBAL ENV") {
                            globalEnvCardContent
                        }

                        LiminalCard(title: "DRUMS") {
                            drumsCardContent
                        }

                        renderButton
                            .padding(.top, LiminalMetrics.stackSmall)
                    }
                    .padding(.horizontal, LiminalMetrics.marginMobile)
                    .padding(.top, LiminalMetrics.stackLarge)
                    .padding(.bottom, LiminalMetrics.stackLarge * 2)
                }
            }

            ScanlineOverlay()
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .fullScreenCover(isPresented: $showRender) {
            RenderScreen(engine: engine, imageName: currentImage.assetName, timestamp: timestamp)
        }
    }

    private var currentImage: LiminalImage { ImageLibrary[imageIndex] }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.liminalCRTGreenDim)
                Text("LIMINAL GENERATOR")
                    .font(.spaceMono(size: 18, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(.liminalTapeHiss)
                    .accessibilityIdentifier("mainHeaderTitle")
            }

            Spacer()

            Button {
                showAbout = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundColor(.liminalOnSurfaceVariant)
            }
        }
        .padding(.horizontal, LiminalMetrics.marginMobile)
        .padding(.vertical, LiminalMetrics.stackMedium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.liminalOutlineVariant)
                .frame(height: 1)
        }
    }

    // MARK: - Image section

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: LiminalMetrics.stackSmall) {
            VHSImageCard(
                index: $imageIndex,
                timestamp: $timestamp,
                isPlaying: engine.isPlaying,
                onTogglePlay: {
                    if engine.isPlaying {
                        engine.pause()
                    } else {
                        engine.play()
                    }
                }
            )

            LiminalChip(text: currentImage.locationName)
        }
    }

    // MARK: - SYNTH card

    private var synthCardContent: some View {
        VStack(spacing: LiminalMetrics.stackMedium) {
            DiceDeckButton(title: "Generate Melody") {
                engine.regenerateMelody()
            }
            .accessibilityIdentifier("generateMelodyButton")

            HStack {
                (Text("PROG: ")
                    .foregroundColor(.liminalOnSurfaceVariant)
                    + Text(engine.currentPattern.displaySeq)
                    .foregroundColor(.liminalCRTGreenDim))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("seqReadout")

                Spacer()

                // effectiveBPM is the engine's single source of truth for
                // displayed tempo: round(baseTempoSource * speedMultiplier),
                // where baseTempoSource is the active loop's bpm while
                // drums are enabled, else the fixed base melody bpm. See
                // SPEC.md's "Musical style" / pinned contract addendum.
                Text("BPM: \(engine.effectiveBPM)")
                    .foregroundColor(.liminalOnSurfaceVariant)
                    .layoutPriority(1)
                    .accessibilityIdentifier("bpmReadout")
            }
            .font(.spaceMono(size: 11))
            .tracking(0.5)

            LiminalSliderRow(
                label: "COLOR",
                subLabel: "TONE",
                leftEndpoint: "DARK",
                rightEndpoint: "BRIGHT",
                value: $engine.color,
                sliderAccessibilityIdentifier: "colorSlider"
            )

            waveformChipRow
        }
    }

    /// Single-select SINE/TRIANGLE/SQUARE/SAW row driving
    /// `engine.waveform` (melody oscillator shape only).
    private var waveformChipRow: some View {
        HStack(spacing: LiminalMetrics.stackSmall) {
            ForEach(LiminalWaveform.allCases, id: \.self) { wave in
                LiminalSelectableChip(
                    text: wave.rawValue,
                    isSelected: engine.waveform == wave
                ) {
                    engine.waveform = wave
                }
                .accessibilityIdentifier("waveformChip_\(wave.rawValue)")
            }
        }
    }

    // MARK: - BASSLINE card

    private var bassCardContent: some View {
        VStack(alignment: .leading, spacing: LiminalMetrics.stackMedium) {
            HStack {
                Text("ENABLE BASS")
                    .font(.spaceMono(size: 12))
                    .tracking(1)
                    .foregroundColor(.liminalTapeHiss)
                Spacer()
                LiminalToggle(isOn: $engine.bassEnabled)
                    .accessibilityIdentifier("bassToggle")
            }
            .padding(.bottom, LiminalMetrics.stackSmall)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.liminalSurfaceContainerHighest)
                    .frame(height: 1)
            }

            if engine.bassEnabled {
                VStack(spacing: LiminalMetrics.stackMedium) {
                    LiminalSliderRow(
                        label: "COLOR",
                        subLabel: "FILTER",
                        leftEndpoint: "DARK",
                        rightEndpoint: "BRIGHT",
                        value: $engine.bassColor,
                        sliderAccessibilityIdentifier: "bassColorSlider"
                    )

                    LiminalSliderRow(
                        label: "LEVEL",
                        subLabel: nil,
                        leftEndpoint: "-INF",
                        rightEndpoint: "+6dB",
                        value: $engine.bassLevel,
                        sliderAccessibilityIdentifier: "bassLevelSlider"
                    )

                    DiceDeckButton(title: "Generate Bass") {
                        engine.regenerateBass()
                    }
                    .accessibilityIdentifier("generateBassButton")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.bassEnabled)
    }

    // MARK: - GLOBAL ENV card

    private var globalEnvCardContent: some View {
        VStack(spacing: LiminalMetrics.stackMedium) {
            LiminalSliderRow(
                label: "SPACE",
                subLabel: "REV_DECAY",
                leftEndpoint: "0",
                rightEndpoint: "10",
                value: $engine.space,
                sliderAccessibilityIdentifier: "spaceSlider"
            )
            LiminalSliderRow(
                label: "AGE",
                subLabel: "WOW_FLUTTER",
                leftEndpoint: "0",
                rightEndpoint: "10",
                value: $engine.age,
                sliderAccessibilityIdentifier: "ageSlider"
            )
            LiminalSliderRow(
                label: "NOSTALGIA",
                subLabel: "BBD_CHORUS",
                leftEndpoint: "0",
                rightEndpoint: "10",
                value: $engine.nostalgia,
                sliderAccessibilityIdentifier: "nostalgiaSlider"
            )
            LiminalSliderRow(
                label: "SPEED",
                subLabel: "TEMPO",
                leftEndpoint: "0",
                rightEndpoint: "10",
                value: $engine.speed,
                sliderAccessibilityIdentifier: "speedSlider"
            )
        }
    }

    // MARK: - DRUMS card

    private var drumsCardContent: some View {
        VStack(alignment: .leading, spacing: LiminalMetrics.stackMedium) {
            HStack {
                Text("ENABLE LOFI BEATS")
                    .font(.spaceMono(size: 12))
                    .tracking(1)
                    .foregroundColor(.liminalTapeHiss)
                Spacer()
                LiminalToggle(isOn: $engine.drumsEnabled)
                    .accessibilityIdentifier("drumsToggle")
            }
            .padding(.bottom, LiminalMetrics.stackSmall)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.liminalSurfaceContainerHighest)
                    .frame(height: 1)
            }

            if engine.drumsEnabled {
                VStack(spacing: LiminalMetrics.stackMedium) {
                    LiminalSliderRow(
                        label: "LEVEL",
                        subLabel: nil,
                        leftEndpoint: "-INF",
                        rightEndpoint: "+6dB",
                        value: $engine.drumLevel,
                        sliderAccessibilityIdentifier: "drumLevelSlider"
                    )

                    DiceDeckButton(title: "Generate Beat") {
                        engine.regenerateBeat()
                    }
                    .accessibilityIdentifier("generateBeatButton")

                    HStack {
                        (Text("LOOP: ")
                            .foregroundColor(.liminalOnSurfaceVariant)
                            + Text(engine.currentBeat.displayName)
                            .foregroundColor(.liminalCRTGreenDim))
                            .accessibilityIdentifier("loopReadout")

                        Spacer()

                        Text("BPM: \(engine.currentBeat.bpm)")
                            .foregroundColor(.liminalOnSurfaceVariant)
                            .accessibilityIdentifier("drumBpmReadout")
                    }
                    .font(.spaceMono(size: 11))
                    .tracking(0.5)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.drumsEnabled)
    }

    // MARK: - Render bar

    private var renderButton: some View {
        Button {
            showRender = true
        } label: {
            HStack(spacing: 10) {
                Text("\u{25CF}")
                Text("RENDER & SHARE")
            }
        }
        .buttonStyle(RenderBarButtonStyle())
        .accessibilityIdentifier("renderShareButton")
    }
}

#Preview {
    MainView()
}
