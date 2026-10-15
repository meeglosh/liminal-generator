//
//  AboutSheet.swift
//  LiminalGenerator
//
//  About sheet with optional native tips and font/image/audio credits,
//  in keeping with the terminal/readout aesthetic.
//

import SwiftUI

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var language: LanguageManager

    var body: some View {
        NavigationStack {
            ZStack {
                Color.liminalBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: LiminalMetrics.stackLarge) {
                        VStack(alignment: .leading, spacing: LiminalMetrics.stackSmall) {
                            Text(verbatim: "LIMINAL GENERATOR")
                                .font(.spaceMono(size: 20, weight: .bold))
                                .foregroundColor(.liminalCRTGreenDim)
                                .tracking(1)
                            Text("Free, generative ambient VHS music player for liminal spaces.")
                                .font(.system(size: 14))
                                .foregroundColor(.liminalOnSurfaceVariant)
                        }

                        TipJarSection()

                        VStack(alignment: .leading, spacing: 16) {
                            Link("PRIVACY POLICY", destination: URL(string: "https://github.com/meeglosh/liminal-generator/blob/codex/app-store-pages/PRIVACY.md")!)
                            Link("HELP & SUPPORT", destination: URL(string: "https://github.com/meeglosh/liminal-generator/tree/codex/app-store-pages")!)
                        }
                        .font(.spaceMono(size: 12, weight: .bold))
                        .foregroundColor(.liminalCRTGreenDim)

                        languageSection

                        creditSection(
                            title: "TYPEFACE",
                            body: Text(verbatim: "Space Mono — Colophon Foundry / Google Fonts.")
                                + Text(verbatim: "\n")
                                + Text("Licensed under the SIL Open Font License.")
                        )

                        creditSection(
                            title: "IMAGERY",
                            body: Text("\(ImageLibrary.count) generated liminal-space stills, bundled with the app and processed live through an on-device VHS filter.")
                        )

                        creditSection(
                            title: "AUDIO",
                            body: Text("Ambient chords and melodies, generated entirely on-device, with optional lo-fi drum loops layered in.")
                        )

                        creditSection(
                            title: "DRUM LOOPS",
                            body: Text("10 lo-fi hip-hop drum loops by holizna, via Freesound.org. Licensed CC0 1.0 (public domain).")
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

    private func creditSection(title: LocalizedStringKey, body: Text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.spaceMono(size: 12, weight: .bold))
                .tracking(2)
                .foregroundColor(.liminalOnSurfaceVariant)
            body
                .font(.spaceMono(size: 12))
                .foregroundColor(.liminalTapeHiss)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// In-app language dropdown: same sharp-cornered, mono, CRT-green look
    /// as the rest of the sheet. See LanguageManager for what follows it.
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LANGUAGE")
                .font(.spaceMono(size: 12, weight: .bold))
                .tracking(2)
                .foregroundColor(.liminalOnSurfaceVariant)
            Menu {
                Picker(selection: $language.selection) {
                    ForEach(AppLanguage.options) { option in
                        if let name = option.nativeName {
                            Text(verbatim: name).tag(option.code)
                        } else {
                            Text("System Default").tag(option.code)
                        }
                    }
                } label: {
                    Text("LANGUAGE")
                }
            } label: {
                HStack(spacing: 8) {
                    if let name = AppLanguage.options.first(where: { $0.code == language.selection })?.nativeName {
                        Text(verbatim: name)
                    } else {
                        Text("System Default")
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                }
                .font(.spaceMono(size: 12, weight: .bold))
                .foregroundColor(.liminalCRTGreenDim)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.liminalSurfaceContainerLow)
                .overlay(Rectangle().stroke(Color.liminalOutlineVariant, lineWidth: 1))
            }
            .accessibilityIdentifier("languagePicker")
        }
    }
}

#Preview {
    AboutSheet().environmentObject(TipStore()).environmentObject(LanguageManager())
}
