#ifndef HERTA_BODY_BASE_RDC_INCLUDED
#define HERTA_BODY_BASE_RDC_INCLUDED

#include "HertaStockingsRdc.hlsl"
#include "ShadowRdc.hlsl"

// EID722/744, frame 3745. Stage 3 only, specialized to captured constants.
// Not a complete MRT shader: stockings (stage 4), rim (5), selfshadow (6),
// and flowing effects (7) are intentionally absent.
// Texture views: BaseColor 4864=sRGB, LightMap 4833=linear,
// Ramp 4830=sRGB, MixMask 4819=sRGB (despite its mask role).
// Bind samplers matching the capture. Do not add another gamma conversion.

struct HertaBodyBaseResult
{
    float3 color;
    float3 baseColor;
    float3 rampColor;
    float3 normalWS;
    float2 rampUV;
    uint materialID;
};

float3 HertaBodyCapturedLightDirection()
{
    // PS722/744 cb0[26], selected by instructions 172-180.
    return float3(-0.380356460809708, 0.435889959335327, 0.815676987171173);
}

uint HertaBodyMaterialID(float lightMapAlpha)
{
    // UNORM input is nonnegative. A=1 wraps to ID0, not ID7.
    // PS722 3-10 / PS744 10-17.
    return ((uint)floor(lightMapAlpha * 8.0)) % 8u;
}

float2 HertaBodyRampUV(float lightMapG, float vertexR,
                       float3 normalWS, float3 lightDirectionWS, uint materialID)
{
    // PS722 325-335. Stage 6 selfshadow visibility is identity at stage 3.
    // Original capture enables selfshadow, so this is an explicit scope omission.
    const float selfShadowVisibility = 1.0;
    float halfLambert = saturate(dot(normalWS, lightDirectionWS) * 0.5 + 0.5);
    float ao = lightMapG * vertexR;
    float lighting = min(1.0, 4.0 * ao * halfLambert * selfShadowVisibility);
    // PS722 371-380, cb4[24]=(1,0,0,0), scene shadow factor=1.
    return float2(0.85 * max(lighting, 0.001) + 0.15,
                  (2.0 * materialID + 1.0) * 0.0625);
}

float3 HertaBodyRemapRamp(float3 ramp)
{
    // PS722 401-425: the branch is based on the SUM, not per component.
    // cb5[7].z=1, [40..43]=(1,1,1,.5), [44]=(0,0,.55,1).
    const float center = 0.550000011920929;
    return dot(ramp, float3(1.0, 1.0, 1.0)) > 2.9
        ? saturate(0.5 + 0.5 * ((ramp - center) / (1.0 - center)))
        : saturate(0.5 - 0.5 * ((center - ramp) / center));
}

HertaBodyBaseResult HertaBodyEvaluateStage3(
    Texture2D<float4> baseColorTexture, SamplerState baseColorSampler,
    Texture2D<float4> lightMapTexture, SamplerState lightMapSampler,
    Texture2D<float4> rampTexture, SamplerState rampSampler,
    Texture2D<float4> mixMaskTexture, SamplerState mixMaskSampler,
    Texture2D<float4> stockingsTexture, SamplerState stockingsSampler,
    float2 uv0, float2 uv1, float vertexR, float3 interpolatedNormalWS,
    bool frontFace, float3 lightDirectionWS, float3 viewDirectionWS,
    float rawCharacterVisibility)
{
    HertaBodyBaseResult result;
    // VS722/744 cb4[1].yz=(0,1), cb4[7]=(1,1,0,0): front UV0/back UV1.
    // VS cb4[5] contains integer ones: vertex R is passed through unchanged.
    // EID722 culls back faces; EID744 is two-sided.
    float2 selectedUV = frontFace ? uv0 : uv1;
    float3 frontColor = baseColorTexture.Sample(baseColorSampler, uv0).rgb;
    float3 selectedColor = baseColorTexture.Sample(baseColorSampler, selectedUV).rgb;
    float mask = mixMaskTexture.Sample(mixMaskSampler, uv0).r;
    // Both tints are white; t7 and t2 share texture + view + sampler.
    // This is identity on the front, but can mix two UVs on the back.
    result.baseColor = lerp(selectedColor, frontColor, mask);
    float4 lightMap = lightMapTexture.Sample(lightMapSampler, selectedUV);
    result.materialID = HertaBodyMaterialID(lightMap.a);
    result.normalWS = normalize(interpolatedNormalWS) * (frontFace ? 1.0 : -1.0);
    result.rampUV = HertaBodyShadowedRampUV(lightMap.g, vertexR, result.normalWS,
        lightDirectionWS, result.materialID, rawCharacterVisibility);

    // PS722 336-370: opaque stocking mask/detail processing precedes the ramp.
    float3 colorBeforeRamp = HertaStockingsBaseCurrentFrame(stockingsTexture,
        stockingsSampler, uv0, result.baseColor, result.normalWS, viewDirectionWS);

    // PS722 381-400: cb5[26].y=0 chooses t5=4830 only.
    // cb2[8].z=0 makes the optional pre-remap shadow tint identity.
    result.rampColor = HertaBodyRemapRamp(rampTexture.Sample(rampSampler, result.rampUV).rgb);
    result.color = colorBeforeRamp * result.rampColor;
    // PS722 437-466: cb2[8].xy=0 makes spatial tint/additive color identity.
    // Caller applies PS722 467-497 material view tint using LUT rows5/6.
    // Height overlay PS722 498-527 is disabled: cb4[96].y=0.
    // Forward adapter returns float4(result.color,1); original MRT packs base RGB
    // into alpha/auxiliary channels and must not be interpreted as transparency.
    return result;
}

#endif
