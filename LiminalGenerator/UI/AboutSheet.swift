//
//  AboutSheet.swift
//  LiminalGenerator
//
//  Minimal "about" sheet opened from the header gear icon: font + image
//  credits, in keeping with the terminal/readout aesthetic.
//

import SwiftUI

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.liminalBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: LiminalMetrics.stackLarge) {
                        VStack(alignment: .leading, spacing: LiminalMetrics.stackSmall) {
                            Text("LIMINAL GENERATOR")
                                .font(.spaceMono(size: 20, weight: .bold))
                                .foregroundColor(.liminalCRTGreenDim)
                                .tracking(1)
                            Text("Free, generative ambient VHS music player for liminal spaces.")
                                .font(.system(size: 14))
                                .foregroundColor(.liminalOnSurfaceVariant)
                        }

                        creditSection(
                            title: "TYPEFACE",
                            lines: [
                                "Space Mono — Colophon Foundry / Google Fonts.",
                                "Licensed under the SIL Open Font License.",
                            ]
                        )

                        creditSection(
                            title: "IMAGERY",
                            lines: [
                                "\(ImageLibrary.count) generated liminal-space stills, bundled",
                                "with the app and processed live through an",
                                "on-device VHS filter.",
                            ]
                        )

                        creditSection(
                            title: "AUDIO",
                            lines: [
                                "Procedural synth arpeggios, generated",
                                "entirely on-device, with optional lo-fi",
                                "drum loops layered in.",
                            ]
                        )

                        creditSection(
                            title: "DRUM LOOPS",
                            lines: [
                                "10 lo-fi hip-hop drum loops by holizna,",
                                "via Freesound.org. Licensed CC0 1.0",
                                "(public domain).",
                            ]
                        )
                    }
                    .padding(LiminalMetrics.marginMobile)
                }
            }
            .navigationTitle("ABOUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.liminalBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { dismiss() }
                        .font(.spaceMono(size: 12, weight: .bold))
                        .foregroundColor(.liminalCRTGreenDim)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func creditSection(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.spaceMono(size: 12, weight: .bold))
                .tracking(2)
                .foregroundColor(.liminalOnSurfaceVariant)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.spaceMono(size: 12))
                    .foregroundColor(.liminalTapeHiss)
            }
        }
    }
}

#Preview {
    AboutSheet()
}
