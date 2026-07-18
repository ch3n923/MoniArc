#include <metal_stdlib>
using namespace metal;

struct HDRGlowUniforms {
    float4 canvas;
    float4 surfaceRect;
    float4 coreColor;
    float4 glowColor;
    float4 animation;
    float4 effects;
    float4 metadata;
};

struct HDRGlowSegment {
    float4 endpoints;
    float4 metrics;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut hdrGlowVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

float distanceToSegment(float2 point, float2 start, float2 end, thread float &segmentT) {
    float2 delta = end - start;
    float denominator = max(dot(delta, delta), 0.0001);
    segmentT = clamp(dot(point - start, delta) / denominator, 0.0, 1.0);
    return distance(point, start + delta * segmentT);
}

float signedDistanceToSurface(float2 point, float4 rect, float radius, bool closesTop) {
    float2 halfSize = rect.zw * 0.5;
    float2 center = rect.xy + halfSize;
    radius = min(radius, min(rect.z, rect.w) * 0.5);
    float localRadius = (closesTop || point.y >= center.y) ? radius : 0.0;
    float2 q = abs(point - center) - halfSize + localRadius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - localRadius;
}

float3 displayP3ToLinear(float3 color) {
    float3 low = color / 12.92;
    float3 high = pow((color + 0.055) / 1.055, float3(2.4));
    return select(low, high, color > 0.04045);
}

float wrappedDistance(float lhs, float rhs) {
    float distanceValue = abs(lhs - rhs);
    return min(distanceValue, 1.0 - distanceValue);
}

float smoothMultiFrequencyNoise(float position, float phase) {
    const float tau = 6.28318530718;
    // Every time frequency is integral. Together with the integral hotspot
    // speeds below this makes phase 0 and phase 1 mathematically identical.
    float first = sin((position * 3.0 + phase) * tau);
    float second = sin((position * 7.0 - phase * 2.0 + 0.21) * tau) * 0.52;
    float third = sin((position * 13.0 + phase * 3.0 + 0.63) * tau) * 0.25;
    return clamp(0.5 + (first + second + third) / 3.54, 0.0, 1.0);
}

float loopWave(float phase, float offset, float cycles) {
    const float tau = 6.28318530718;
    return 0.5 - 0.5 * cos((phase * cycles + offset) * tau);
}

float movingFlare(
    float pathProgress,
    float phase,
    float origin,
    float speed,
    float width,
    float energy
) {
    float center = fract(origin + phase * speed);
    float profile = exp(-0.5 * pow(wrappedDistance(pathProgress, center) / width, 2.0));
    return profile * energy;
}

fragment float4 hdrGlowFragment(
    VertexOut in [[stage_in]],
    constant HDRGlowUniforms &uniforms [[buffer(0)]],
    constant HDRGlowSegment *segments [[buffer(1)]]
) {
    float2 point = in.position.xy;
    uint segmentCount = uint(uniforms.metadata.x + 0.5);
    float closestDistance = 1e6;
    float pathProgress = 0.0;

    for (uint index = 0; index < segmentCount; ++index) {
        float segmentT = 0.0;
        float distanceValue = distanceToSegment(
            point,
            segments[index].endpoints.xy,
            segments[index].endpoints.zw,
            segmentT
        );
        if (distanceValue < closestDistance) {
            closestDistance = distanceValue;
            pathProgress = segments[index].metrics.x + segments[index].metrics.y * segmentT;
        }
    }

    float scale = uniforms.canvas.z;
    float coreWidth = uniforms.effects.y;
    float coreHalfWidth = coreWidth * 0.5;
    float pathAA = max(fwidth(closestDistance), 0.75);
    float coreCoverage = 1.0 - smoothstep(
        max(0.0, coreHalfWidth - pathAA),
        coreHalfWidth + pathAA,
        closestDistance
    );

    int motionKind = int(uniforms.effects.w + 0.5);
    bool isFlow = motionKind == 1;
    float solarFlareBlend = clamp(uniforms.metadata.w, 0.0, 1.0);
    bool hasSolarFlare = solarFlareBlend > 0.0001;
    float phase = uniforms.animation.x;
    float flareEnergy = 0.0;
    float haloScale = 1.0;
    float solarHaloWeight = 1.0;
    float solarHaloScale = 1.0;

    if (hasSolarFlare) {
        float noise = smoothMultiFrequencyNoise(pathProgress, phase);
        float largePulse = loopWave(phase, 0.17, 1.0);
        float largeEchoPulse = loopWave(phase, 0.49, 1.0);
        float mediumPulse = loopWave(phase, 0.63, 2.0);
        float mediumEchoPulse = loopWave(phase, 0.06, 2.0);
        float smallPulse = loopWave(phase, 0.34, 3.0);
        float emberPulse = loopWave(phase, 0.81, 2.0);
        // High-cycle envelopes create short, seemingly random eruptions while
        // still returning to their exact initial value at the loop boundary.
        float burstAPulse = pow(loopWave(phase, 0.22, 5.0), 3.0);
        float burstBPulse = pow(loopWave(phase, 0.71, 4.0), 4.0);
        float sparkPulse = pow(loopWave(phase, 0.46, 7.0), 3.0);

        // A few different flare families make the edge feel alive without
        // turning the whole island into a permanently illuminated outline.
        float largeFlare = movingFlare(
            pathProgress, phase, 0.12, 1.0,
            mix(0.090, 0.190, largePulse),
            mix(0.22, 0.76, largePulse)
        );
        float largeEchoFlare = movingFlare(
            pathProgress, phase, 0.76, -1.0,
            mix(0.075, 0.165, largeEchoPulse),
            mix(0.16, 0.63, largeEchoPulse)
        );
        float mediumFlare = movingFlare(
            pathProgress, phase, 0.57, -2.0,
            mix(0.048, 0.105, mediumPulse),
            mix(0.18, 0.66, mediumPulse)
        );
        float mediumEchoFlare = movingFlare(
            pathProgress, phase, 0.93, 2.0,
            mix(0.040, 0.090, mediumEchoPulse),
            mix(0.14, 0.54, mediumEchoPulse)
        );
        float smallFlare = movingFlare(
            pathProgress, phase, 0.31, 3.0,
            mix(0.018, 0.046, smallPulse),
            mix(0.28, 0.92, smallPulse)
        );
        float emberFlare = movingFlare(
            pathProgress, phase, 0.83, -1.0,
            mix(0.030, 0.072, emberPulse),
            mix(0.12, 0.45, emberPulse)
        );
        float burstAFlare = movingFlare(
            pathProgress, phase, 0.44, 4.0,
            mix(0.020, 0.115, burstAPulse),
            mix(0.04, 0.92, burstAPulse)
        );
        float burstBFlare = movingFlare(
            pathProgress, phase, 0.05, -3.0,
            mix(0.026, 0.145, burstBPulse),
            mix(0.03, 0.86, burstBPulse)
        );
        float sparkFlare = movingFlare(
            pathProgress, phase, 0.68, 5.0,
            mix(0.012, 0.040, sparkPulse),
            mix(0.02, 0.70, sparkPulse)
        );
        float coronaTexture = smoothstep(0.58, 0.93, noise);
        float rawEnergy = 0.018 + coronaTexture * 0.055 + largeFlare
            + largeEchoFlare + mediumFlare + mediumEchoFlare + smallFlare + emberFlare
            + burstAFlare + burstBFlare + sparkFlare;
        flareEnergy = smoothstep(0.06, 1.02, rawEnergy);
        // The two short burst fields do not merely brighten: they expand the
        // corona far beyond its resting radius at their exact local position.
        float eruptionField = smoothstep(0.08, 0.72, max(burstAFlare, burstBFlare));
        // Keep the Sol look as a broad corona, not a sharp yellow stroke.
        // Active flares brighten the corona itself instead of redrawing the
        // island's edge, so black and gold never meet at a hard line.
        solarHaloScale = mix(1.48, 2.28, flareEnergy) + eruptionField * 0.88;
        solarHaloWeight = max(smoothstep(0.10, 0.92, flareEnergy), eruptionField);
    }

    haloScale = mix(1.0, solarHaloScale, solarFlareBlend);
    float solarHaloSpread = mix(
        1.0,
        mix(1.35, 1.82, solarHaloWeight),
        solarFlareBlend
    );
    float nearGlow = exp(-0.5 * pow(closestDistance / (1.8 * scale * haloScale), 2.0)) * 0.25 * solarHaloSpread;
    float middleGlow = exp(-0.5 * pow(closestDistance / (4.8 * scale * haloScale), 2.0)) * 0.17 * solarHaloSpread;
    float outerGlow = exp(-0.5 * pow(closestDistance / (9.5 * scale * haloScale), 2.0)) * 0.090 * solarHaloSpread;
    float haloCoverage = min(0.48, nearGlow + middleGlow + outerGlow);

    bool closesTop = uniforms.canvas.w > 0.5;
    float surfaceDistance = signedDistanceToSurface(
        point,
        uniforms.surfaceRect,
        uniforms.effects.z,
        closesTop
    );
    float surfaceAA = max(fwidth(surfaceDistance), 0.75);
    float surfaceCoverage = 1.0 - smoothstep(-surfaceAA, surfaceAA, surfaceDistance);
    haloCoverage *= (1.0 - surfaceCoverage) * uniforms.metadata.y;

    float bandWeight = 0.0;
    if (isFlow) {
        float relativeProgress = fract(pathProgress - phase + 1.0);
        float bandLength = uniforms.animation.y;
        float edge = min(0.025, bandLength * 0.2);
        bandWeight = smoothstep(0.0, edge, relativeProgress)
            * (1.0 - smoothstep(bandLength - edge, bandLength, relativeProgress));
    }

    float coreBrightness = uniforms.animation.z;
    float haloBrightness = uniforms.animation.w;
    float coreEnergy = uniforms.metadata.z;
    float haloEnergy = uniforms.metadata.z;

    if (isFlow) {
        coreBrightness = mix(uniforms.animation.z, uniforms.animation.w, bandWeight);
        haloBrightness = mix(uniforms.effects.x, uniforms.animation.w, bandWeight);
        coreEnergy = mix(0.70, 1.0, bandWeight);
        haloEnergy = mix(0.30, 1.0, bandWeight);
    } else if (hasSolarFlare) {
        float solarCoreBrightness = mix(uniforms.animation.z, uniforms.animation.w, flareEnergy);
        float solarHaloBrightness = mix(uniforms.effects.x, uniforms.animation.w, flareEnergy);
        float solarHaloEnergy = mix(0.84, 1.82, solarHaloWeight);
        coreBrightness = mix(coreBrightness, solarCoreBrightness, solarFlareBlend);
        haloBrightness = mix(haloBrightness, solarHaloBrightness, solarFlareBlend);
        coreEnergy = mix(coreEnergy, 0.0, solarFlareBlend);
        haloEnergy = mix(haloEnergy, solarHaloEnergy, solarFlareBlend);
        coreCoverage *= 1.0 - solarFlareBlend;
    }

    float3 coreLinear = displayP3ToLinear(uniforms.coreColor.rgb);
    float3 glowLinear = displayP3ToLinear(uniforms.glowColor.rgb);
    float haloAlpha = min(1.0, haloCoverage * haloEnergy);
    float combinedAlpha = clamp(max(surfaceCoverage, max(coreCoverage, haloAlpha)), 0.0, 1.0);
    float3 premultipliedColor = coreLinear * coreBrightness * coreCoverage * coreEnergy
        + glowLinear * haloBrightness * haloAlpha;

    return float4(premultipliedColor, combinedAlpha);
}
