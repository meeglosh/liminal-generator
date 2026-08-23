//
//  Theme.swift
//  LiminalGenerator
//
//  Design-system tokens (color, type, shape) transcribed from
//  img/stitch_liminal_space_generator/liminal_analog/DESIGN.md and SPEC.md.
//  Phase 1 only defines the tokens; screens are built out in Phase 2.
//

import SwiftUI

// MARK: - Colors

extension Color {
    // Surfaces (deep charcoal void)
    static let liminalSurface = Color(hex: 0x131313)
    static let liminalSurfaceDim = Color(hex: 0x131313)
    static let liminalSurfaceBright = Color(hex: 0x393939)
    static let liminalSurfaceContainerLowest = Color(hex: 0x0E0E0E)
    static let liminalSurfaceContainerLow = Color(hex: 0x1C1B1B)
    static let liminalSurfaceContainer = Color(hex: 0x201F1F)
    static let liminalSurfaceContainerHigh = Color(hex: 0x2A2A2A)
    static let liminalSurfaceContainerHighest = Color(hex: 0x353534)

    // Text
    static let liminalOnSurface = Color(hex: 0xE5E2E1) // "tape hiss" off-white
    static let liminalTapeHiss = Color(hex: 0xE5E2E1)
    static let liminalOnSurfaceVariant = Color(hex: 0xBACCB1)
    static let liminalInverseSurface = Color(hex: 0xE5E2E1)
    static let liminalInverseOnSurface = Color(hex: 0x313030)

    // Outlines
    static let liminalOutline = Color(hex: 0x85967D)
    static let liminalOutlineVariant = Color(hex: 0x3C4B36)

    // Primary — CRT green
    static let liminalCRTGreen = Color(hex: 0x33FF33)       // primary-container
    static let liminalCRTGreenDim = Color(hex: 0x00E61B)    // surface-tint / primary-fixed-dim
    static let liminalPrimary = Color(hex: 0xEEFFE4)
    static let liminalOnPrimary = Color(hex: 0x003A02)
    static let liminalOnPrimaryContainer = Color(hex: 0x007207)
    static let liminalInversePrimary = Color(hex: 0x006E06)

    // Secondary — glitch magenta
    static let liminalGlitchMagenta = Color(hex: 0xFE00FE) // secondary-container
    static let liminalSecondary = Color(hex: 0xFFABF3)
    static let liminalOnSecondary = Color(hex: 0x5B005B)
    static let liminalOnSecondaryContainer = Color(hex: 0x500050)

    // Tertiary / neutral
    static let liminalTertiary = Color(hex: 0xFBFAF9)
    static let liminalOnTertiary = Color(hex: 0x2F3131)
    static let liminalTertiaryContainer = Color(hex: 0xDEDDDD)
    static let liminalOnTertiaryContainer = Color(hex: 0x606161)

    // Error
    static let liminalError = Color(hex: 0xFFB4AB)
    static let liminalOnError = Color(hex: 0x690005)
    static let liminalErrorContainer = Color(hex: 0x93000A)
    static let liminalOnErrorContainer = Color(hex: 0xFFDAD6)

    // Background
    static let liminalBackground = Color(hex: 0x131313)
    static let liminalOnBackground = Color(hex: 0xE5E2E1)
    static let liminalSurfaceVariant = Color(hex: 0x353534)

    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Fonts

extension Font {
    /// Space Mono if bundled successfully; otherwise the system monospaced
    /// font. Register `Space Mono` / `Space Mono Bold` via UIAppFonts in
    /// Info.plist for the bundled path to succeed.
    static func spaceMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let familyName = weight == .bold ? "Space Mono Bold" : "Space Mono"
        if UIFont.fontNames(forFamilyName: "Space Mono").isEmpty
            && UIFont(name: familyName, size: size) == nil {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(familyName, size: size)
    }
}

// MARK: - Shape / metrics

enum LiminalMetrics {
    /// Structural UI containers are strictly sharp-cornered (0 radius).
    static let cornerRadiusSharp: CGFloat = 0
    /// Only "hardware" buttons get a tiny radius for a tactile feel.
    static let cornerRadiusHardware: CGFloat = 2
    /// Thick bottom border used on deck-style buttons to fake depth.
    static let deckButtonBorderWidth: CGFloat = 2
    static let spacingUnit: CGFloat = 4
    static let gutter: CGFloat = 16
    static let marginMobile: CGFloat = 20
    static let stackSmall: CGFloat = 8
    static let stackMedium: CGFloat = 16
    static let stackLarge: CGFloat = 32
}
