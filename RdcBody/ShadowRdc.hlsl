#ifndef HERTA_CHARACTER_SHADOW_RDC_INCLUDED
#define HERTA_CHARACTER_SHADOW_RDC_INCLUDED

// Frame 3745, PS722/744 and PS1514/1537 only.
// Face uses a separate camera-depth lookup; hair has no character-map lookup.
// The caller owns the live 1536x1536 depth texture and world-to-shadow matrix.
// Capture: D16 resource 5714, comparison sampler 1093, strict Greater, linear.
// Use the comparison convention matching the generated depth on other backends.

// PS722 224-251: paired weights/offsets for the 7x7 tent kernel.
// Four bilinear comparisons per axis produce sixteen total comparisons.
void HertaShadowTentAxis(float fractionalOffset, out float4 weights,
    out float4 offsets)
{
    float o = fractionalOffset;
    float a = (o + 0.5) * (o + 0.5);
    float negative = min(o, 0.0);
    float positive = max(o, 0.0);
    float4 left = float4(1.0 - o, 3.0 - o - negative * negative,
                         2.0 + o, 0.5 * a) * (4.0 / 49.0);
    float4 right = float4(0.5 * a - o, 2.0 - o,
                          3.0 + o - positive * positive, 1.0 + o)
        * (4.0 / 49.0);
    weights = left + right;
    offsets = left / weights + float4(-3.5, -1.5, 0.5, 2.5);
}

float HertaCharacterShadowPCF(Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler, float3 shadowUVZ, float4 texelSize)
{
    float2 center = floor(shadowUVZ.xy * texelSize.zw + 0.5);
    float2 offset = shadowUVZ.xy * texelSize.zw - center;
    float4 wx, wy, ox, oy;
    HertaShadowTentAxis(offset.x, wx, ox);
    HertaShadowTentAxis(offset.y, wy, oy);
    float visibility = 0.0;
    [unroll] for (int y = 0; y < 4; ++y)
    {
        [unroll] for (int x = 0; x < 4; ++x)
        {
            float2 uv = (center + float2(ox[x], oy[y])) * texelSize.xy;
            visibility += wx[x] * wy[y]
                * shadowMap.SampleCmpLevelZero(shadowSampler, uv, shadowUVZ.z);
        }
    }
    return visibility;
}

// worldToShadowUVZ already includes the xy scale/bias into [0,1].
// Pass a normalized, front/back-flipped normal, as used for body lighting.
// Captured arguments: normalOffset=.001, atlasST=(1,1,0,0), enabled=1,
// texelSize=(1/1536,1/1536,1536,1536).
// Returns RAW visibility. Do not apply strength here: the additional body
// shader's existing HertaBodyShadowCurrentFrame already applies .4+.6*raw.
float HertaCharacterShadowRaw(Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler, float3 positionWS, float3 normalWS,
    float4x4 worldToShadowUVZ, float4 atlasST, float4 texelSize,
    float normalOffset, float enabled)
{
    if (enabled <= 0.0) return 1.0;
    float4 projected = mul(worldToShadowUVZ,
        float4(positionWS + normalWS * normalOffset, 1.0));
    float3 shadowUVZ = projected.xyz / projected.w;
    // UV bounds are checked BEFORE atlas transform, matching PS722 214-220.
    if (any(shadowUVZ.xy < 0.0) || any(shadowUVZ.xy > 1.0)
        || shadowUVZ.z <= 0.0 || shadowUVZ.z >= 1.0) return 1.0;
    shadowUVZ.xy = shadowUVZ.xy * atlasST.xy + atlasST.zw;
    return HertaCharacterShadowPCF(shadowMap, shadowSampler, shadowUVZ, texelSize);
}

float HertaCharacterShadowStrength(float rawVisibility)
{
    // PS722 323-324 cb4[3].w=.6; PS1514 189 uses literal .6/.4.
    return 0.4 + 0.6 * rawVisibility;
}

float2 HertaBodyShadowedRampUV(float lightMapG, float vertexR,
    float3 normalWS, float3 lightDirectionWS, uint materialID,
    float rawCharacterVisibility)
{
    float halfLambert = saturate(dot(normalWS, lightDirectionWS) * 0.5 + 0.5);
    float lighting = min(1.0, 4.0 * lightMapG * vertexR * halfLambert
        * HertaCharacterShadowStrength(rawCharacterVisibility));
    return float2(0.15 + 0.85 * max(lighting, 0.001),
        (2.0 * materialID + 1.0) * 0.0625);
}

float4x4 HertaCapturedWorldToCharacterShadow()
{
    // cb2[15..18] are COLUMNS, not rows. Captured world space only.
    // For a relocated/scaled model, compose its world-to-captured transform.
    return float4x4(
        -0.7951077223, 0.0, -0.0841468200, 0.4675234556,
         0.0143924849, 0.4541399479, -0.1359953582, 0.0552372336,
        -0.0357566364, 0.1023095921, 0.3378663361, 0.3145322204,
         0.0, 0.0, 0.0, 1.0);
}

#endif
