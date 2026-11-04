#ifndef HERTA_BODY_FLOW_RDC_INCLUDED
#define HERTA_BODY_FLOW_RDC_INCLUDED

// PS1514 instructions 378-403, 458-464; PS1537 is offset by +7.
// Current capture only: cb4[72].y == 0 selects screen coordinates; the
// object-coordinate candidate and cb4[71].y == 0 edge color are inactive.
// Texture contract: t6 is linear BC7, t7 and t5 are sRGB BC7 views.
// samplerFlow / samplerNoise must be repeat, bilinear min/mag,
// point mip selection, with a total LOD bias of -1 (see integration.md).
// This helper supplies the -1 through SampleBias. Do not apply it twice.

float HertaBodyFlowTime(float unityTimeSeconds, float freeze, float frozenTime)
{
    return freeze > 0.5 ? frozenTime : unityTimeSeconds;
}

float2 HertaBodyFlowScreenUV(float2 normalizedScreenUV, float4 screenTransform)
{
    // PS0-2: cb0[36] = 0 in both recorded body additional draws.
    // Input/output are viewport UV, not RTHandle-scaled sample coordinates.
    return normalizedScreenUV * (1.0 - screenTransform.xy) + screenTransform.zw;
}

float3 HertaBodyFlowScreenCurrentFrame(
    Texture2D<float4> flowTexture, SamplerState samplerFlow,
    Texture2D<float4> noiseTexture, SamplerState samplerNoise,
    float2 screenUV, float cameraDistance, float2 frontUV,
    float maskR, float timeSeconds)
{
    // cb4[66].x = 1, [63] = (4,4,0,0), [65].xy = (0,.02).
    float2 flowUV = (screenUV - 0.5) * cameraDistance;
    flowUV = flowUV * float2(4.0, 4.0)
        + timeSeconds * float2(0.0, 0.019999999552965164);
    float flowR = flowTexture.SampleBias(samplerFlow, flowUV, -1.0).r;

    // cb4[72].y = 0 means r6.xy = v1.xy, including on the back face.
    // [68] = (1,1,0,0), [69] = (1,.02,0,0).
    // Scalar time offset is added to BOTH U and V; it is not V-only.
    float noisePhase = timeSeconds * 0.019999999552965164;
    float noiseSumR = noiseTexture.SampleBias(samplerNoise,
        frontUV + noisePhase.xx, -1.0).r
        + noiseTexture.SampleBias(samplerNoise,
        frontUV - noisePhase.xx, -1.0).r;

    // PS389 and PS460 each multiply the SAME unsaturated t5.R mask.
    // Both original samples of t6 use .r, as confirmed by DXBC swizzles.
    float3 flow = flowR * float3(0.19375671446323395,
        0.14717859029769897, 1.0);
    flow *= 40.0;
    flow *= maskR;
    flow *= noiseSumR;
    flow *= maskR;
    return flow;
}

#endif
