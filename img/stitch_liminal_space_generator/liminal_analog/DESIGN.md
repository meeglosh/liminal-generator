---
name: Liminal Analog
colors:
  surface: '#131313'
  surface-dim: '#131313'
  surface-bright: '#393939'
  surface-container-lowest: '#0e0e0e'
  surface-container-low: '#1c1b1b'
  surface-container: '#201f1f'
  surface-container-high: '#2a2a2a'
  surface-container-highest: '#353534'
  on-surface: '#e5e2e1'
  on-surface-variant: '#baccb1'
  inverse-surface: '#e5e2e1'
  inverse-on-surface: '#313030'
  outline: '#85967d'
  outline-variant: '#3c4b36'
  surface-tint: '#00e61b'
  primary: '#eeffe4'
  on-primary: '#003a02'
  primary-container: '#33ff33'
  on-primary-container: '#007207'
  inverse-primary: '#006e06'
  secondary: '#ffabf3'
  on-secondary: '#5b005b'
  secondary-container: '#fe00fe'
  on-secondary-container: '#500050'
  tertiary: '#fbfaf9'
  on-tertiary: '#2f3131'
  tertiary-container: '#dedddd'
  on-tertiary-container: '#606161'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#76ff65'
  primary-fixed-dim: '#00e61b'
  on-primary-fixed: '#002201'
  on-primary-fixed-variant: '#005303'
  secondary-fixed: '#ffd7f5'
  secondary-fixed-dim: '#ffabf3'
  on-secondary-fixed: '#380038'
  on-secondary-fixed-variant: '#810081'
  tertiary-fixed: '#e3e2e2'
  tertiary-fixed-dim: '#c7c6c6'
  on-tertiary-fixed: '#1a1c1c'
  on-tertiary-fixed-variant: '#464747'
  background: '#131313'
  on-background: '#e5e2e1'
  surface-variant: '#353534'
typography:
  display-vcr:
    fontFamily: Space Mono
    fontSize: 32px
    fontWeight: '700'
    lineHeight: '1.2'
    letterSpacing: -0.05em
  headline-lg:
    fontFamily: Space Mono
    fontSize: 24px
    fontWeight: '700'
    lineHeight: 32px
  headline-lg-mobile:
    fontFamily: Space Mono
    fontSize: 20px
    fontWeight: '700'
    lineHeight: 28px
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-mono:
    fontFamily: Space Mono
    fontSize: 12px
    fontWeight: '400'
    lineHeight: 16px
    letterSpacing: 0.1em
  status-readout:
    fontFamily: Space Mono
    fontSize: 10px
    fontWeight: '400'
    lineHeight: 12px
spacing:
  unit: 4px
  gutter: 16px
  margin-mobile: 20px
  margin-desktop: 40px
  stack-sm: 8px
  stack-md: 16px
  stack-lg: 32px
---

## Brand & Style
The design system establishes an atmospheric tension between modern iOS precision and the decaying warmth of analog media. It targets a niche audience of lo-fi enthusiasts and "liminal space" explorers who seek a solitary, immersive experience.

The style is a hybrid of **Minimalism** and **Retro-Technological**. It utilizes high-contrast typography and extreme whitespace to create a sense of vast, empty scale, punctuated by "glitch" accents and CRT textures. The UI should evoke the feeling of operating a piece of high-end surveillance or broadcast equipment from the 1990s—functional, slightly eerie, and clinical yet nostalgic.

## Colors
The palette is rooted in the "void"—a deep charcoal background that allows phosphor accents to vibrate visually.

- **Primary (CRT Green):** Used for active states, playback status, and "safe" information. 
- **Secondary (Glitch Magenta):** Reserved for alerts, high-energy interactions, or subtle "artifact" highlights.
- **Neutral (Deep Charcoal/Muted Gray):** The primary surface color, providing enough contrast against the pure black "void" of the background.
- **Tape Hiss (Off-White):** Used for all primary reading text to reduce the harshness of pure white on dark backgrounds, mimicking aged physical media.

## Typography
The system uses a dual-type approach. **Inter** provides the necessary legibility for complex settings and long-form descriptions, ensuring the app remains a functional iOS tool. **Space Mono** acts as the thematic anchor, used for headers, status readouts, and data points to simulate a terminal or VCR interface.

- **Headlines:** Always monospaced and frequently uppercase to mimic digital hardware displays.
- **Body:** Clean, humanist sans-serif for high readability in low-light environments.
- **Labels:** Small, monospaced tracking for "technical data" feel.

## Layout & Spacing
This design system utilizes a **fixed grid** with wide margins to emphasize the "liminal" feeling of isolation. Content should often feel slightly "lost" in the dark space.

- **Grid:** A 12-column grid for desktop/tablet, collapsing to a single column for mobile.
- **Rhythm:** An 8px base unit is used for component sizing, but a 4px "micro-grid" is used for tight technical readouts.
- **Negative Space:** Over-index on vertical padding between sections to create a sense of eerie quiet.

## Elevation & Depth
Depth is achieved through **Tonal Layers** and **Scanline Overlays** rather than traditional shadows.

- **Surfaces:** Level 0 is the background (#000000). Level 1 is the surface container (#121212).
- **Outlines:** Use "Low-contrast outlines" in muted grays (#2A2A2A) to define shapes. 
- **Texture:** A persistent, low-opacity (2-3%) noise or scanline overlay should be applied to the entire UI to simulate a CRT screen. 
- **Active State:** Instead of lifting an object with a shadow, increase its border brightness or add a subtle CRT "glow" (outer blur) in the Primary color.

## Shapes
The shape language is strictly **Sharp (0)**. Everything from buttons to card containers uses 90-degree corners to evoke the hardware limitations of 80s/90s industrial design and early digital interfaces. 

Occasionally, a very small (2px) radius may be used only for physical "hardware" buttons to give them a tactile, pressed feel, but for all structural UI containers, the corners remain sharp.

## Components
- **Buttons (Deck Controls):** Styled to look like physical tape deck keys. Use a thick bottom border (2px) to simulate depth. Active states should "depress" by removing the bottom border and shifting the label down by 1px.
- **Cards (VCR Static):** Sharp-edged boxes with a subtle horizontal scanline pattern overlay. Headers on cards should look like labeled tape spines.
- **Sliders (Analog Faders):** High-contrast tracks with a blocky, rectangular thumb. The "fill" of the slider should be the CRT Green.
- **Status Readouts:** Small blocks of monospaced text, often preceded by a blinking square cursor to indicate "live" processing.
- **Chips/Tags:** Monospaced text inside a simple thin-lined box. No fills, only outlines.
- **Input Fields:** Styled as a single horizontal line (like a terminal prompt) rather than a box, using a block cursor.
- **Glitches:** Occasionally, hover states or transitions should trigger a brief "chromatic aberration" effect where the RGB channels of the component separate slightly.