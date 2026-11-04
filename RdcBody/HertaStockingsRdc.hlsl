#ifndef HERTA_STOCKINGS_RDC_INCLUDED
#define HERTA_STOCKINGS_RDC_INCLUDED

// Frame 3745, PS722 181-200/336-370 and PS744 188-207/343-377.
// Base pass only. PS1514/1537 have NO stocking texture/color transform.
// t6=4835, SRV4836: linear BC7, all 12 original mips. Sampler1111:
// Repeat, linear min/mag, point mip selection, mip bias -1.
// The supplied sampler must already carry bias -1; do not apply it twice.

float3 HertaStockingsCapturedBasis(float3 v)
{
    // PS cb1[23..25].xyz, preserving the source's linear combination.
    return v.y * float3(0.0, 1.0, 0.0)
        + v.x * float3(-1.0, 0.0, 8.742277657347586e-8)
        + v.z * float3(8.742277657347586e-8, 0.0, 1.0);
}

float HertaStockingsViewCosine(float3 orientedNormalWS, float3 viewDirectionWS)
{
    // Inputs are normalized; N includes the SV_IsFrontFace sign.
    // cb4[38].xyz=0. Source renormalizes transformed V, but not transformed N.
    float3 n = HertaStockingsCapturedBasis(orientedNormalWS);
    float3 v = normalize(HertaStockingsCapturedBasis(viewDirectionWS));
    return saturate(dot(n, v));
}

float3 HertaStockingsFromSamples(float3 mixedBaseColor, float2 maskRG,
    float tiledB, float viewCosine)
{
    // Captured cb4[53].rgb=(1,1,1), so the inner tint lerp is identity.
    // cb4[54]=(.4000000059604645,1,5,.25).
    float n = max(viewCosine, 0.001);
    float q = saturate((n - 1.0) / (0.4000000059604645 - 1.0));
    q = q * q * (3.0 - 2.0 * q);
    q *= 0.25;
    q *= maskRG.r > 0.001 ? 1.0 : 0.0;
    q *= maskRG.r;
    float3 densityMultiplier = 1.0 + q * (mixedBaseColor - 1.0);
    float3 densityColor = mixedBaseColor * densityMultiplier;

    // cb4[55]=(1,.30000001192092896,0,0).
    float detail = 1.0 + (0.5 * tiledB - 0.5);
    float brightWeight = (1.0 - 0.30000001192092896) * (detail * maskRG.g);
    brightWeight = saturate(brightWeight * max(exp2(log2(n) * 5.0), 0.004));
    float3 tint = float3(0.5204590559005737, 0.450471967458725,
        0.5271152257919312);
    return densityColor + brightWeight * (tint - densityColor);
}

float3 HertaStockingsBaseCurrentFrame(Texture2D<float4> stockingsTexture,
    SamplerState stockingsSampler, float2 frontUV, float3 mixedBaseColor,
    float3 orientedNormalWS, float3 viewDirectionWS)
{
    // Both samples use FRONT UV even on PS744 back faces.
    // Destination .z in PS722 instruction337 selects B, not R.
    float tiledB = stockingsTexture.Sample(stockingsSampler, frontUV * 30.0).b;
    float2 maskRG = stockingsTexture.Sample(stockingsSampler, frontUV).rg;
    return HertaStockingsFromSamples(mixedBaseColor, maskRG, tiledB,
        HertaStockingsViewCosine(orientedNormalWS, viewDirectionWS));
}

#endif
