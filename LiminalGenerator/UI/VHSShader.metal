//
//  VHSShader.metal
//  LiminalGenerator
//
//  Original lightweight analog treatment inspired by NTSCRT's signal -> CRT
//  pipeline (no upstream shader code). Color bandwidth is softer than luma;
//  tape weave/head switching precede scanlines, highlight glow and grain.
//  The live and Core Image export paths use visually comparable treatments.
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
    float tapeWeave = sin(time * 2.0 * M_PI_F * 0.7) * 0.0008;
    float headBand = smoothstep(0.965, 0.995, uv.y);
    float headShift = sin(time * 2.0 * M_PI_F * 7.0) * 0.009 * headBand;
    float2 samplePos = position + float2((jitterX + (tapeWeave + headShift) * energy) * size.x, 0.0);
    samplePos.x = clamp(samplePos.x, 0.0, size.x - 1.0);

    // Blur chroma horizontally while retaining sharp center luminance.
    // Unlike RGB channel separation this smears color without double edges.
    float spread = size.x * (4.0 / 848.0);
    half4 center = layer.sample(samplePos);
    half3 left = layer.sample(clamp(samplePos - float2(spread, 0.0), float2(0.0), size - 1.0)).rgb;
    half3 right = layer.sample(clamp(samplePos + float2(spread * 2.0, 0.0), float2(0.0), size - 1.0)).rgb;
    half3 soft = center.rgb * 0.4h + left * 0.2h + right * 0.4h;
    half3 weights = half3(0.299h, 0.587h, 0.114h);
    half luma = dot(center.rgb, weights);
    half softLuma = dot(soft, weights);
    half4 color = half4(half3(luma) + (soft - half3(softLuma)) * 0.88h, center.a);
    // Restrained bloom around bright windows/lights, rather than a haze
    // over the whole photo. Extra wide horizontal taps suggest phosphor glow.
    half3 glowLeft = layer.sample(clamp(samplePos - float2(spread * 3.0, 0.0), float2(0.0), size - 1.0)).rgb;
    half3 glowRight = layer.sample(clamp(samplePos + float2(spread * 3.0, 0.0), float2(0.0), size - 1.0)).rgb;
    half3 glow = max((glowLeft + glowRight + soft) / 3.0h - 0.65h, 0.0h);
    color.rgb += glow * 0.12h;

    // --- Scanlines: ~2.4pt period (point-space equivalent of the pinned
    // ~2px @ 848px reference), strength ~0.18 with ±20% slow temporal
    // modulation so the band isn't perfectly static.
    const float scanlinePeriod = 2.4;
    float scanFreq = (2.0 * M_PI_F) / scanlinePeriod;
    float scan = sin(uv.y * size.y * scanFreq) * 0.5 + 0.5;
    float scanStrength = 0.18 * (1.0 + 0.2 * sin(time * 2.0 * M_PI_F * 0.17));
    float scanMul = mix(1.0 - scanStrength, 1.0, scan);
    color.rgb *= half(scanMul);

    // --- Animated luma grain (amplitude 0.019 — reduced 75% from the prior
    // 0.075 per SPEC.md addendum; kept in parity with the render pipeline's
    // Core Image grain amplitude), refreshed every frame.
    float grainSeed = vhsHash(floor(uv * 848.0) + fmod(floor(time * 30.0), 1000.0));
    color.rgb += half3((grainSeed - 0.5) * 0.019);

    // --- Tracking-glitch band: brightened noise burst on top of the smear.
    float glitchNoise = vhsHash(uv * size + time * 37.0) - 0.5;
    color.rgb += half3(inBand * (0.12 + glitchNoise * 0.25));

    // --- Vignette (unchanged) ---------------------------------------------
    float vig = 1.0 - smoothstep(0.35, 0.95, length(uv - 0.5));
    color.rgb *= mix(0.55, 1.0, vig);

    return half4(clamp(color.rgb, 0.0h, 1.0h), color.a);
}
