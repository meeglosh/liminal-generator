//
//  VHSShader.metal
//  LiminalGenerator
//
//  Live VHS look for the image card: scanlines, animated luma noise/grain,
//  chroma aberration (stronger toward the edges) + a subtle overall chroma
//  bleed/desaturation, vignette, and a periodic vertical-sweeping tracking
//  glitch band. Driven by a time uniform from a SwiftUI TimelineView.
//
//  Intensity targets are PINNED in SPEC.md Addendum 5 item 5 and shared with
//  the render agent's Core Image VHSFrameCompositor so the live look and the
//  rendered clip land within visual matching distance of each other:
//    - scanlines: ~2px period @ 848px reference, strength ~0.18, ±20%
//      temporal modulation. This shader runs in the view's point-space (not
//      the 848px raster the render pipeline works in), so "2px @ 848" is
//      implemented as a similarly tight, clearly-legible period in point
//      space (~2.4pt) rather than a literal fraction-of-848 rescale, which
//      at typical on-screen card sizes would collapse to sub-pixel noise.
//    - grain: animated luma noise, amplitude ~0.06-0.09, refreshed/frame.
//    - tracking glitch: ~20-40px band (@848 ref, expressed as a uv-fraction
//      of height so it *is* reference-scaled) sweeping vertically over
//      ~0.2-0.4s, recurring every ~4-9s (randomized).
//    - color bleed: chroma aberration at edges +~50% vs the prior build,
//      plus a subtle always-on desaturation/bleed.
//    - vignette: unchanged.
//  Kept cheap: no loops, a handful of ALU ops + 3 layer samples per pixel.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Cheap hash -> pseudo-random float in [0, 1).
static float vhsHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

[[ stitchable ]]
half4 vhsEffect(float2 position, SwiftUI::Layer layer, float2 size, float time, float energy) {
    if (size.x <= 0.0 || size.y <= 0.0) {
        return layer.sample(position);
    }

    float2 uv = position / size;

    // --- Tracking glitch: a band sweeps top->bottom over ~0.2-0.4s, once
    // every ~4-9s (randomized). Stateless/time-driven: each ~6.5s window
    // gets its own randomized start offset + duration + band thickness via
    // hashing the window index, so consecutive glitches don't look
    // identical and the recurrence reads as irregular rather than metronomic.
    const float glitchPeriod = 6.5; // s, ~ midpoint of the pinned 4-9s range
    float glitchWindowIndex = floor(time / glitchPeriod);
    float glitchDuration = mix(0.2, 0.4, vhsHash(float2(glitchWindowIndex, 3.7)));
    float glitchStartFrac = vhsHash(float2(glitchWindowIndex, 8.2)) * (1.0 - glitchDuration / glitchPeriod);
    float glitchStartTime = glitchWindowIndex * glitchPeriod + glitchStartFrac * glitchPeriod;
    float tLocal = (time - glitchStartTime) / glitchDuration;
    float glitchActive = step(0.0, tLocal) * step(tLocal, 1.0) * energy;

    // 20-40px band height @ 848px reference, expressed as a uv-fraction of
    // height (pixels/848) so it scales naturally with the view's own size.
    float bandHalfWidthUV = mix(10.0, 20.0, vhsHash(float2(glitchWindowIndex, 1.1))) / 848.0;
    float bandCenterUV = clamp(tLocal, 0.0, 1.0); // sweeps top -> bottom across the duration
    float inBand = step(fabs(uv.y - bandCenterUV), bandHalfWidthUV) * glitchActive;

    float jitterX = (vhsHash(float2(glitchWindowIndex, floor(uv.y * 160.0))) - 0.5) * 0.06 * inBand;
    float2 samplePos = position + float2(jitterX * size.x, 0.0);
    samplePos.x = clamp(samplePos.x, 0.0, size.x - 1.0);

    // --- Chroma aberration: stronger near the horizontal edges (+~50% vs
    // the prior build's edge value), plus a nonzero center baseline for a
    // subtle always-on color bleed.
    float edgeDist = fabs(uv.x - 0.5) * 2.0;
    float aberration = mix(1.2, 5.25, edgeDist * edgeDist);

    half4 colR = layer.sample(clamp(samplePos + float2(aberration, 0.0), float2(0.0), size - 1.0));
    half4 colG = layer.sample(samplePos);
    half4 colB = layer.sample(clamp(samplePos - float2(aberration, 0.0), float2(0.0), size - 1.0));

    half4 color = half4(colR.r, colG.g, colB.b, colG.a);

    // Subtle overall chroma desaturation (VHS color softness).
    half luma = dot(color.rgb, half3(0.299h, 0.587h, 0.114h));
    color.rgb = mix(color.rgb, half3(luma, luma, luma), 0.06h);

    // --- Scanlines: ~2.4pt period (point-space equivalent of the pinned
    // ~2px @ 848px reference), strength ~0.18 with ±20% slow temporal
    // modulation so the band isn't perfectly static.
    const float scanlinePeriod = 2.4;
    float scanFreq = (2.0 * M_PI_F) / scanlinePeriod;
    float scan = sin(uv.y * size.y * scanFreq) * 0.5 + 0.5;
    float scanStrength = 0.18 * (1.0 + 0.2 * sin(time * 2.0 * M_PI_F * 0.17));
    float scanMul = mix(1.0 - scanStrength, 1.0, scan);
    color.rgb *= half(scanMul);

    // --- Animated luma grain (amplitude ~0.06-0.09, refreshed every frame).
    float grainSeed = vhsHash(uv * size + fmod(time * 24.0, 1000.0));
    color.rgb += half3((grainSeed - 0.5) * 0.075);

    // --- Tracking-glitch band: brightened noise burst on top of the smear.
    float glitchNoise = vhsHash(uv * size + time * 37.0) - 0.5;
    color.rgb += half3(inBand * (0.12 + glitchNoise * 0.25));

    // --- Vignette (unchanged) ---------------------------------------------
    float vig = smoothstep(0.95, 0.35, length(uv - 0.5));
    color.rgb *= mix(0.55, 1.0, vig);

    return half4(clamp(color.rgb, 0.0h, 1.0h), color.a);
}
