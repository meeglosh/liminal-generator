//
//  VHSShader.metal
//  LiminalGenerator
//
//  Live VHS look for the image card: scanlines, animated luma noise/grain,
//  slight chroma aberration (stronger toward the edges), vignette, and an
//  occasional brief horizontal tracking-jitter band. Driven by a time
//  uniform from a SwiftUI TimelineView. Kept cheap: no loops, a handful of
//  ALU ops + 3 layer samples per pixel.
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

    // --- Occasional brief horizontal tracking jitter -----------------
    // A new "roll" window every ~1/6s; most windows are quiet, a rare few
    // briefly displace a thin horizontal band.
    float rollIndex = floor(time * 6.0);
    float rollChance = vhsHash(float2(rollIndex, 5.17));
    float rollActive = step(0.93, rollChance) * energy;
    float bandCenter = vhsHash(float2(rollIndex, 9.31));
    float bandHalfWidth = 0.035;
    float inBand = step(fabs(uv.y - bandCenter), bandHalfWidth) * rollActive;
    float jitterX = (vhsHash(float2(rollIndex, floor(uv.y * 160.0))) - 0.5) * 0.05 * inBand;

    float2 samplePos = position + float2(jitterX * size.x, 0.0);
    samplePos.x = clamp(samplePos.x, 0.0, size.x - 1.0);

    // --- Chroma aberration (stronger near the horizontal edges) ------
    float edgeDist = fabs(uv.x - 0.5) * 2.0;
    float aberration = mix(1.0, 3.5, edgeDist * edgeDist);

    half4 colR = layer.sample(clamp(samplePos + float2(aberration, 0.0), float2(0.0), size - 1.0));
    half4 colG = layer.sample(samplePos);
    half4 colB = layer.sample(clamp(samplePos - float2(aberration, 0.0), float2(0.0), size - 1.0));

    half4 color = half4(colR.r, colG.g, colB.b, colG.a);

    // --- Scanlines -----------------------------------------------------
    float scan = sin(uv.y * size.y * 1.3) * 0.5 + 0.5;
    color.rgb *= mix(0.82, 1.0, scan);

    // --- Animated luma grain -------------------------------------------
    float grainSeed = vhsHash(uv * size + fmod(time * 24.0, 1000.0));
    color.rgb += half3((grainSeed - 0.5) * 0.05);

    // --- Vignette --------------------------------------------------------
    float vig = smoothstep(0.95, 0.35, length(uv - 0.5));
    color.rgb *= mix(0.55, 1.0, vig);

    return half4(clamp(color.rgb, 0.0h, 1.0h), color.a);
}
