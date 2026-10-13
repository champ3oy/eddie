import Foundation

/// Metal source of the grade kernel, compiled at launch with `CIKernel.kernels(withMetalString:)`
/// (no Metal toolchain needed at build time).
enum GradeKernelSource {
    static let metal = #"""
// The grade: ten knobs applied to Rec.709 (display-encoded) pixels coming out of the LUT.
// All knob values arrive normalized: exposure in EV, everything else in -1...1.
//
//   p0 = (exposure, temperature, tint, contrast)
//   p1 = (highlights, shadows, whites, blacks)
//   p2 = (vibrance, saturation, unused, unused)

#include <CoreImage/CoreImage.h>
using namespace metal;

namespace {
    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);   // Rec.709 luma weights
    constant float kGamma = 2.4;                               // BT.1886 display gamma
    constant float kPivot = 0.45;                              // mid-gray in display space

    float3 toLinear(float3 v) { return pow(max(v, 0.0), kGamma); }
    float3 toDisplay(float3 v) { return pow(max(v, 0.0), 1.0 / kGamma); }

    // Monotonic for |k| <= 1, leaves 0, pivot and 1 in place.
    float contrastCurve(float y, float k) {
        float t = clamp(y, 0.0, 1.0);
        float w = t < kPivot ? t / kPivot : (1.0 - t) / (1.0 - kPivot);
        return y + k * (t - kPivot) * w;
    }
}

[[stitchable]] float4 eddieGrade(coreimage::sample_t s, float4 p0, float4 p1, float4 p2) {
    float3 c = clamp(s.rgb, 0.0, 1.0);

    // --- White balance + exposure, in linear light ---
    float3 lin = toLinear(c);
    float temp = p0.y, tint = p0.z;
    // Temperature moves only red against blue; tint moves only green against red+blue.
    // Tint is brightness-normalized (green dominates luma); temperature isn't, because
    // normalizing it would pull green down and turn "warmer" into "pinker".
    float3 tempGains = float3(1.0 + 0.50 * temp, 1.0, 1.0 - 0.50 * temp);
    float3 tintGains = float3(1.0, 1.0 - 0.50 * tint, 1.0);
    tintGains /= dot(tintGains, kLuma);
    lin *= tempGains * tintGains * exp2(p0.x);
    float3 v = toDisplay(lin);

    // --- Tone, on luma ---
    float y = dot(v, kLuma);
    float t = clamp(y, 0.0, 1.0);
    float d = 0.0;
    d += p1.x * 0.30 * 6.75 * t * t * (1.0 - t);               // highlights (peaks at 2/3)
    d += p1.y * 0.30 * 6.75 * t * (1.0 - t) * (1.0 - t);       // shadows (peaks at 1/3)
    d += p1.z * 0.15 * t * t * t;                              // whites
    d += p1.w * 0.10 * (1.0 - t) * (1.0 - t) * (1.0 - t);      // blacks
    // Highlights below zero also pulls down over-exposed (>1) values so detail can come back.
    if (y > 1.0 && p1.x < 0.0) { d += p1.x * 0.5 * (y - 1.0); }
    float y2 = contrastCurve(y + d, 0.8 * p0.w);
    v += (y2 - y);

    // --- Color ---
    float yl = dot(v, kLuma);
    float3 chroma = v - yl;
    float sat = max(v.r, max(v.g, v.b)) - min(v.r, min(v.g, v.b));
    float vib = 1.0 + p2.x * (1.0 - smoothstep(0.0, 0.6, sat));
    float factor = max(0.0, 1.0 + p2.y) * max(0.0, vib);
    v = yl + chroma * factor;

    return float4(clamp(v, 0.0, 1.0), s.a);
}
"""#
}
