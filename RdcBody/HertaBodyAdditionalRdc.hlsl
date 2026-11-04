#ifndef HERTA_BODY_ADDITIONAL_RDC_INCLUDED
#define HERTA_BODY_ADDITIONAL_RDC_INCLUDED

#include "OutlineRdc.hlsl"

// PS1514; PS1537 uses the same material equations after face-dependent UV selection.
// Stage 3 subset: no stocking transform, depth rim, or flowing emission.
// Those deferred effects ARE present in the capture; their omission is task scope.
// Caller supplies the already selected light and raw character-shadow visibility.

float HertaBodySmooth01(float x)
{
    x = saturate(x);
    return x * x * (3.0 - 2.0 * x);
}

int HertaBodyMaterialId(float lightMapAlpha)
{
    // UNorm source: alpha == 1 wraps to ID 0, not ID 7.
    return (int)(((uint)floor(lightMapAlpha * 8.0)) % 8u);
}

float2 HertaBodyFaceUV(float4 packedUV, bool frontFace, bool doubleSidedVariant)
{
    return doubleSidedVariant && !frontFace ? packedUV.zw : packedUV.xy;
}

float3 HertaBodyMixedAlbedo(float3 selectedBaseRGB, float3 layerAtFrontUV,
    float maskAtFrontUV)
{
    // Current tint/ST = identity. Back-side base/light map use packedUV.zw;
    // layer and mask still use packedUV.xy in PS1537.
    return lerp(selectedBaseRGB, layerAtFrontUV, maskAtFrontUV);
}

float3 HertaBodySelectedLightDirection(float3 cb0_26, float3 cb2_0,
    float cb2_14x, float cb5_26z, float4 cb4_9,
    float cb4_0w, float3 cb5_2)
{
    bool sceneLight = cb5_26z + 1.0 - abs(cb2_14x) > 0.5;
    float3 L = sceneLight ? cb0_26 : cb2_0;
    // Source does not normalize L after this interpolation.
    L = lerp(L, cb4_9.xyz, cb4_9.w);
    return cb4_0w > 0.5 ? cb5_2 : L;
}

float3 HertaBodySelectedLightColor(float3 cb0_27, float3 cb2_1,
    float cb2_14x, float cb5_26z)
{
    return cb5_26z + 1.0 - abs(cb2_14x) > 0.5 ? cb0_27 : cb2_1;
}

float HertaBodyShadowCurrentFrame(float rawCharacterVisibility)
{
    // Screen shadow is sampled from t0.R, then lerped to 1 by cb5[32].y=1.
    // cb5[26].z=1 bypasses cb2[0].w. Character PCF is remapped to [.4,1].
    // Caller returns 1 for disabled projection or outside UV/depth bounds.
    return 0.4 + 0.6 * rawCharacterVisibility;
}

float3 HertaBodyHalfVector(float3 N, float3 V, float3 L)
{
    // Reproduce instructions 54-67, including the near-opposition transition.
    // Exact V+L == 0 has an undefined normalize in DXBC as well.
    float3 sum = V + L;
    float q = HertaBodySmooth01(min(length(sum) * 10000.0, 1.0));
    return normalize(q * (normalize(sum) + N) - N);
}

float3 HertaBodySpecular(Texture2D<float4> materialLut, float4 lightMap,
    float3 N, float3 V, float3 L, float rawCharacterVisibility)
{
    int id = HertaBodyMaterialId(lightMap.a);
    float3 color = materialLut.Load(int3(id, 0, 0)).rgb;
    float3 row1 = materialLut.Load(int3(id, 1, 0)).rgb;
    float p = pow(max(dot(N, HertaBodyHalfVector(N, V, L)), 0.01), row1.r);
    float halfWidth = max(row1.g, 0.001);
    float threshold = 1.0 - lightMap.b;
    float gate = HertaBodySmooth01((HertaBodyShadowCurrentFrame(rawCharacterVisibility)
        * p - (threshold - halfWidth)) / (2.0 * halfWidth));
    // cb5[29]=(1,1,1,.5), cb5[30].x=1 => current global color factor = 1.
    return color * row1.b * gate;
}

float3 HertaBodyHeightColor(float worldY, float objectBaseY)
{
    float h = worldY - objectBaseY;
    float low = 1.0 - HertaBodySmooth01(h / 0.400000005960464);
    float high = HertaBodySmooth01(2.0 * (h - 0.200000002980232));
    float middle = saturate(1.0 - low - high);
    float3 lowRGB = float3(0.313725501298904, 0.313725501298904, 0.490196079015732);
    return 2.0 * saturate(0.5 * (low * lowRGB + middle + high));
}

float3 HertaBodyLutGain(Texture2D<float4> materialLut, int id)
{
    // Instruction 371 writes .w through source swizzle .xywz => row6.B.
    return 1.0 + materialLut.Load(int3(id, 6, 0)).b
        * materialLut.Load(int3(id, 7, 0)).rgb;
}

float3 HertaBodyStage3TargetBeforeDistanceFog(Texture2D<float4> materialLut,
    float3 baseSceneRGB, float4 selectedBase, float3 mixedAlbedoRGB,
    float4 lightMap, float3 normalWS, float3 cameraMinusPositionWS,
    bool frontFace, float3 lightDirection, float3 lightColor,
    float rawCharacterVisibility, float worldY, float objectBaseY,
    float currentLinear01Depth, float offsetLinear01Depth)
{
    float3 N = normalize(normalWS) * (frontFace ? 1.0 : -1.0);
    float3 V = normalize(cameraMinusPositionWS);
    float3 specular = HertaBodySpecular(materialLut, lightMap, N, V,
        lightDirection, rawCharacterVisibility);
    // PS222-240: selectedBase.a is the texture alpha after front/back tint.
    float alphaWeight = saturate((selectedBase.a - 0.5) / 0.5);
    float3 color = lerp(baseSceneRGB, 2.0 * mixedAlbedoRGB, alphaWeight);
    color = (color + specular * mixedAlbedoRGB) * lightColor;
    color = HertaBodyDepthRimCurrentFrame(materialLut, color, lightMap, N, V,
        lightDirection, rawCharacterVisibility, currentLinear01Depth,
        offsetLinear01Depth);
    // Fresnel color cb4[40].rgb and additive cb5[28].rgb are zero in this frame.
    color *= HertaBodyHeightColor(worldY, objectBaseY);
    color *= HertaBodyLutGain(materialLut, HertaBodyMaterialId(lightMap.a));
    return color;
}

float2 HertaBodyDistanceFogCoordinates(float cameraDistance)
{
    // Current start lerp = .1: 300->800 starts at350; 10->130 starts at22.
    float2 q = saturate((cameraDistance - float2(350.0, 22.0))
        / float2(450.0, 108.0));
    // This is q + q^2 - q^3, NOT smoothstep(q).
    return q + q * (q - q * q);
}

float3 HertaBodyDistanceFogCurrentFrame(float3 color, float worldY,
    float cameraDistance, float3 fogColorA, float3 fogColorB)
{
    // t9.SampleLevel(s9,float2(q.x,.98828125),0) and
    // t9.SampleLevel(s9,float2(q.y,.97265625),0) supply fogColorA/B.
    float2 q = HertaBodyDistanceFogCoordinates(cameraDistance);
    float height = 1.0 - min(max(worldY - 6.0, 0.0) / 41.0, 1.0);
    float3 a = lerp(color, fogColorA * q.x, q.x);
    float3 b = lerp(a, height * fogColorB * q.y, q.y);
    float3 heightBlend = lerp(a, b, height);
    float3 additive = a + height * b * q.y;
    float maxFogB = max(fogColorB.r, max(fogColorB.g, fogColorB.b));
    return lerp(heightBlend, additive, maxFogB);
}

float4 HertaBodySignedDelta(float3 finalTargetRGB, float3 baseSceneRGB,
    float volumeTransmittance)
{
    // PS522 and 535-539. Blend One One, do not saturate/clamp the signed delta.
    // If cb3[0].z <= 0, caller supplies volumeTransmittance=1.
    return float4((finalTargetRGB - baseSceneRGB) * volumeTransmittance, 1.0);
}

#endif
