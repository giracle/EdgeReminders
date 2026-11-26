#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// xy is the touch point in view coordinates, z is age in seconds, and w is strength.
static float2 waveSlope(float2 position, float4 impulse) {
    if (impulse.w <= 0.0 || impulse.z >= 1.05) {
        return float2(0.0);
    }

    const float2 offset = position - impulse.xy;
    const float distance = length(offset);
    const float age = impulse.z;
    const float travel = distance - 630.0 * age;
    const float envelope = travel / (27.0 + 42.0 * age);
    const float damping = exp(-envelope * envelope - 3.1 * age) * rsqrt(1.0 + distance / 125.0);
    const float fadeIn = smoothstep(0.0, 0.036, age);
    const float fadeOut = 1.0 - smoothstep(0.78, 1.05, age);
    const float phase = travel * 0.136 - 0.00011 * travel * travel;
    const float slope = sin(phase) * damping * fadeIn * fadeOut * impulse.w;
    return offset / max(9.0, distance) * slope;
}

[[ stitchable ]] half4 panelWaterRipple(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float4 first,
    float4 second,
    float4 third
) {
    const float2 slope = waveSlope(position, first) + waveSlope(position, second) + waveSlope(position, third);
    const float2 displacement = clamp(slope * 17.0, float2(-23.0), float2(23.0));
    const float2 sample = clamp(position + displacement, float2(0.5), max(float2(0.5), size - 0.5));
    const half4 refracted = layer.sample(sample);

    // The system composites the native glass behind this app-owned optical layer.
    const float lighting = dot(slope, float2(-0.62, -0.78));
    const half crest = half(clamp(lighting * 0.24, 0.0, 0.22));
    const half trough = half(clamp(-lighting * 0.25, 0.0, 0.22));
    const half4 shaded = half4(refracted.rgb * (1.0h - trough), refracted.a + (1.0h - refracted.a) * trough * 0.36h);
    return shaded * (1.0h - crest) + half4(0.83h, 0.97h, 1.0h, 1.0h) * crest;
}
