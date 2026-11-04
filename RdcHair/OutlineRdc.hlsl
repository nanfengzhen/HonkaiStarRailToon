#ifndef HERTA_OUTLINE_RDC_INCLUDED
#define HERTA_OUTLINE_RDC_INCLUDED

// Evidence: PS1396 instructions 93-177; PS1514 241-345; PS1537 248-352.
// The caller supplies world-space normalized N (flipped on back faces) and V.
// Screen UV must address the opaque depth snapshot. Do not sample a depth target
// while writing to it. Linear01 means eye depth / camera far, NOT eye depth.

float HertaOutlineSmooth01(float x)
{
    x = saturate(x);
    return x * x * (3.0 - 2.0 * x);
}

float HertaFaceOutlineVertexMask(float4 vertexColor, float3 viewDirectionOS,
    float4 face182, float4 face183, float face226z)
{
    // VS816 0-65. viewDirectionOS = normalize(worldToObject3x3 * Vworld).
    float side = HertaOutlineSmooth01((viewDirectionOS.x - 0.1) * 5.0);
    float start = lerp(face182.y, face182.w, side);
    float end = lerp(face182.z, face183.x, side);
    float facing = dot(float2(0.076, 0.961), viewDirectionOS.xy);
    float blueGate = HertaOutlineSmooth01((1.0 - facing - start) / (end - start));
    float selectedBlue = vertexColor.b < 0.99 ? vertexColor.b : 0.0;
    float width = selectedBlue > 0.0 ? blueGate * selectedBlue : vertexColor.a;
    width += vertexColor.g > 0.0 && vertexColor.g < 1.0 ? face226z : 0.0;
    float a = dot(float3(-0.206, 0.961, face183.y), viewDirectionOS);
    float b = dot(float3(-0.206, 0.961, -face183.y), viewDirectionOS);
    float gateA = HertaOutlineSmooth01(max((0.1 - saturate(max(a,b))) * 9.999998, 0.0));
    float gateB = HertaOutlineSmooth01((saturate(facing) - face183.z) * 20.0);
    return width * lerp(1.0, min(max(gateA, gateB), 1.0), vertexColor.g);
}

float3 HertaOutlineViewPosition(float3 positionVS, float3 extrusionDirectionVS,
    float vertexWidth, float materialWidth, float globalScale,
    float projectionYY, float objectScaleSquared, float disableAmount,
    float2 distanceOverride)
{
    // VS816 63-110. Supply direction after the source normal-matrix transform.
    // The source discards transformed Z and substitutes -0.1 BEFORE normalizing.
    float distanceScale = sqrt(abs(positionVS.z / projectionYY) / globalScale);
    if (distanceOverride.x != 0.0) distanceScale = distanceOverride.y;
    float width = vertexWidth * materialWidth * globalScale * distanceScale
        * sqrt(abs(objectScaleSquared)) * (1.0 - disableAmount);
    float3 direction = normalize(float3(extrusionDirectionVS.xy, -0.1));
    return positionVS + direction * width;
}

float3 HertaHairBodyOutlineViewPosition(float3 positionVS,
    float3 extrusionDirectionVS, float4 vertexColor, float cameraDistance,
    float materialWidth, float globalScale, float projectionYY,
    float objectScaleSquared, float disableAmount, float2 distanceOverride,
    float2 distanceRange, float depthBias)
{
    // VS842/870 32-63. Blue is an optional view-depth bias, alpha is width.
    // This is separate from the face-only B/G/A angular mask above.
    float blue = vertexColor.b < 0.99 ? vertexColor.b : 0.0;
    positionVS.z -= blue * depthBias * 0.01;
    float distanceGate = HertaOutlineSmooth01((cameraDistance - distanceRange.x)
        / (distanceRange.y - distanceRange.x));
    float vertexWidth = vertexColor.a * (1.0 + min(distanceGate, 0.5));
    return HertaOutlineViewPosition(positionVS, extrusionDirectionVS,
        vertexWidth, materialWidth, globalScale, projectionYY,
        objectScaleSquared, disableAmount, distanceOverride);
}

float3 HertaFaceOutlineCurrentFrame(float3 positionVS, float3 extrusionDirectionVS,
    float4 vertexColor, float3 viewDirectionOS, float projectionYY)
{
    float mask = HertaFaceOutlineVertexMask(vertexColor, viewDirectionOS,
        float4(0.0, 0.600000023841858, 0.649999976158142, 0.699999988079071),
        float4(0.699999988079071, 0.600000023841858, 0.200000002980232, 0.0), 0.0);
    return HertaOutlineViewPosition(positionVS, extrusionDirectionVS, mask,
        0.04, 0.015, projectionYY, 1.0, 0.0, float2(0.0, 3.0));
}

float3 HertaHairBodyOutlineCurrentFrame(float3 positionVS,
    float3 extrusionDirectionVS, float4 vertexColor, float cameraDistance,
    float projectionYY, bool body)
{
    return HertaHairBodyOutlineViewPosition(positionVS, extrusionDirectionVS,
        vertexColor, cameraDistance, body ? 0.05 : 0.04, 0.015,
        projectionYY, 1.0, 0.0, float2(0.0, 3.0), float2(6.5, 18.0), 0.0);
}

float3 HertaFaceOutlineColorCurrentFrame()
{
    return float3(0.124771840870380, 0.0241576302796602, 0.0202885624021292);
}

float3 HertaHairOutlineColorCurrentFrame()
{
    return float3(0.0998987406492233, 0.0528606548905373, 0.0648032799363136);
}

float3 HertaBodyOutlineColorCurrentFrame(Texture2D<float4> materialLut,
    float lightMapAlpha)
{
    // PS870 does NOT wrap material ID; unlike the body additional pass.
    return materialLut.Load(int3((int)floor(lightMapAlpha * 8.0), 2, 0)).rgb;
}

float HertaRimLinear01(float deviceDepth, float2 depthDecode)
{
    // Capture cb1[1].xy = (10239,1), far = 1024, near = 0.1.
    // For a perspective URP camera pass _ZBufferParams.xy here.
    return rcp(depthDecode.x * deviceDepth + depthDecode.y);
}

float2 HertaRimDepthUV(float2 screenUV, float linear01Depth, float farPlane,
    float3 N, float3 V, float lightMapR, float maskStrength,
    float materialWidth, float4 globalOffset)
{
    // Source uses WORLD XZ orientation, not view-space N.xy.
    // Strict comparison matters at zero: zero selects +1, unlike sign(0).
    float side = V.z * N.x - V.x * N.z > 0.0 ? -1.0 : 1.0;
    float width = lerp(1.0, lightMapR, maskStrength) * materialWidth;
    float du = side * width * globalOffset.w * 0.0055
        / (linear01Depth * farPlane + 3.0);
    return screenUV + float2(du, 0.0) + globalOffset.xy * 0.01;
}

float HertaRimDepthGate(float currentLinear01, float offsetLinear01,
    float depthExponent, float materialThreshold)
{
    float separation = pow(max(offsetLinear01 - currentLinear01, 0.000001),
        depthExponent);
    float edge = HertaOutlineSmooth01((separation - 0.82) * 12.500003);
    // Source is threshold < edge, not step(threshold, edge).
    return edge > materialThreshold ? edge : 0.0;
}

float HertaRimLighting(float lightMapG, float3 N, float3 selectedLightDirection,
    float screenVisibility, float characterShadowRemapped)
{
    // Hair passes characterShadowRemapped=1. Body supplies .4+.6*PCF.
    // Current frame's screen-shadow remapping makes screenVisibility=1.
    return 4.0 * lightMapG * saturate(dot(N, selectedLightDirection) * 0.5 + 0.5)
        * screenVisibility * screenVisibility * characterShadowRemapped;
}

float3 HertaRimComposite(float3 preRimColor, float3 rimColorAfterGlobalLight,
    float rimIntensity, float edge, float ndotv, float lighting,
    float blendMode, float lightInfluence, float additiveStrength)
{
    // Material triplet is cb4[33].xyz = (threshold, blendMode, lightInfluence).
    // Body LUT row4 is stored (blendMode, threshold, lightInfluence).
    float3 rim = rimColorAfterGlobalLight * edge * rimIntensity;
    float grazing = 1.0 - ndotv;
    float weight = saturate((1.0 + (lighting - 1.0) * lightInfluence)
        * grazing * dot(rim, float3(0.212671, 0.715160, 0.072169)));
    float3 ordinary = lerp(preRimColor, rim, weight) + rim * additiveStrength;
    float exponent = 1.0 + pow(max(grazing, 0.001), lightInfluence);
    float3 powered = lerp(pow(max(preRimColor, 0.001), exponent), rim, weight);
    return lerp(powered, ordinary, blendMode);
}

float3 HertaHairDepthRimCurrentFrame(float3 preRimColor, float4 lightMap,
    float3 N, float3 V, float3 L, float currentLinear01, float offsetLinear01)
{
    float gate = HertaRimDepthGate(currentLinear01, offsetLinear01, 0.015, 0.9);
    float3 color = float3(0.575444221496582, 0.461128234863281, 0.476217925548553);
    return HertaRimComposite(preRimColor, color * 0.5, 2.5, gate, dot(N,V),
        HertaRimLighting(lightMap.g, N, L, 1.0, 1.0), 1.0, 0.6, 0.0);
}

float3 HertaBodyDepthRimCurrentFrame(Texture2D<float4> materialLut,
    float3 preRimColor, float4 lightMap, float3 N, float3 V, float3 L,
    float rawCharacterVisibility, float currentLinear01, float offsetLinear01)
{
    int id = (int)((uint)floor(lightMap.a * 8.0) % 8u);
    float3 color = materialLut.Load(int3(id, 3, 0)).rgb;
    float3 parameters = materialLut.Load(int3(id, 4, 0)).rgb;
    float gate = HertaRimDepthGate(currentLinear01, offsetLinear01, 0.015,
        parameters.g);
    float lighting = HertaRimLighting(lightMap.g, N, L, 1.0,
        0.4 + 0.6 * rawCharacterVisibility);
    return HertaRimComposite(preRimColor, color * 0.5, 2.5, gate, dot(N,V),
        lighting, parameters.r, parameters.b, 0.0);
}

// PS870 35-57, before distance/height fog. Body outline selects LUT row2.
float3 HertaOutlineBodyColor(float3 materialOutlineRGB, float3 N,
    float3 selectedLightDirection, float4 global32, float material37z,
    float material127x, float global1x)
{
    float lit = HertaOutlineSmooth01(dot(selectedLightDirection, N) * 6.666667);
    float3 color = materialOutlineRGB * lerp(1.0 - global32.z, 1.0, lit)
        + lit * global32.w;
    return color * (1.0 - material37z) * (1.0 - material127x * global1x);
}

#endif
