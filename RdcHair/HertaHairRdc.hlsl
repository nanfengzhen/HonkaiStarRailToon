#ifndef HERTA_HAIR_RDC_INCLUDED
#define HERTA_HAIR_RDC_INCLUDED

// F:/技术美术作品集/the herta.rdc, EID 658 / 680 / 1396.
// Pure arithmetic helpers. Textures must be sampled in their captured view color
// space. Pass vectors in one common world coordinate system. L is the selected
// capture light vector: do not substitute an unrelated direction or invert it.
// See hair-formula-notes.md for instruction evidence and integration boundaries.

float HertaHairRdcSmooth01(float x)
{
    return x * x * (3.0 - 2.0 * x);
}

// E658:154-180; E680:48-75. shadow is exactly one in this frame.
// The DXBC dp2 duplicates both operands: 4*G*halfLambert, NOT 2*G*halfLambert.
float2 HertaHairRdcRampUV(float3 normalWS, float3 lightDirectionWS,
                         float lightMapG)
{
    float halfLambert = saturate(dot(normalWS, lightDirectionWS) * 0.5 + 0.5);
    float illumination = min(1.0, 4.0 * lightMapG * halfLambert);
    return float2(0.15 + 0.85 * max(illumination, 0.001), 0.0625);
}

// E658:181-220; E680:76-121.
// coldRampRGB = t4.Sample(s4, HertaHairRdcRampUV(...)).rgb.
// cb2[8].z=0: the computed shadow tint contributes exactly nothing this frame.
float3 HertaHairRdcBaseRGB(float3 diffuseRGB, float3 coldRampRGB)
{
    float3 r = coldRampRGB;
    // cb5[7].z=1, [42]=[43]=(1,1,1,.5), [44]=(0,0,.55,1).
    // Keep the actual float pivot rather than rounding it to mathematical .55.
    const float pivot = 0.550000011920929;
    float3 mapped = dot(r, float3(1.0, 1.0, 1.0)) > 2.9
        ? saturate(0.5 + 0.5 * ((r - pivot) / (1.0 - pivot)))
        : saturate(0.5 - 0.5 * ((pivot - r) / pivot));
    return diffuseRGB * mapped;
}

// VS680:31,35-42. Run at the VERTEX, then perspective-interpolate the scalar.
// c4/c5/c6 are VS cb2[4/5/6].xyz. Their weighted sum is the captured
// world-to-object direction transform, not a normal/view dot product.
float HertaHairRdcVertexViewFactor(float3 cameraMinusWorld,
                                 float3 c4, float3 c5, float3 c6)
{
    float3 localView = cameraMinusWorld.x * c4 + cameraMinusWorld.y * c5 +
                       cameraMinusWorld.z * c6;
    return dot(normalize(localView).xy, float2(0.276, 0.961));
}

// E680:119-121 and 188-197. diffuseAlpha is t1.A (front/back tint A is 1).
// q must be the interpolated VS output o6.w; see vertex helper/evidence notes.
// This alpha applies ONLY to the stencil Equal17 draw, which also writes depth.
float HertaHairRdcLocalAlpha(float q, float diffuseAlpha)
{
    float x = 1.0 - saturate((q - 0.30000001192092896) * 0.8999999761581421);
    return lerp(0.5 + 0.5 * x, x, diffuseAlpha);
}

// E1396:29-70. Actual half-width is zero. D3D saturate(NaN)=0 means
// the exact threshold equality goes to zero; step(edge,x) would return one.
float HertaHairRdcSpecularMask(float3 normalWS, float3 viewDirectionWS,
                             float3 lightDirectionWS, float lightMapB)
{
    float3 h = normalize(viewDirectionWS + lightDirectionWS);
    float p = min(exp2(log2(max(dot(normalWS, h), 0.01)) * 10.0), 1.0);
    return p > (1.0 - lightMapB) ? 1.0 : 0.0;
}

// E1396:43-48, 55-71, 79-92. Base-scene input is sampled t4, not Diffuse.
// Alpha-emission gate is zero for captured t1.A in [0,1] since cb4[19].z=1.
// LColor must come from the same selected light source as L.
float3 HertaHairRdcAdditionalBeforeDepthRim(float3 baseSceneRGB, float3 diffuseRGB,
    float3 lightMapRGB, float3 normalWS, float3 viewDirectionWS,
    float3 lightDirectionWS, float3 lightColorRGB)
{
    float halfLambert = saturate(dot(normalWS, lightDirectionWS) * 0.5 + 0.5);
    float litGate = 4.0 * lightMapRGB.g * halfLambert > 0.800000011920929 ? 1.0 : 0.0;
    float mask = HertaHairRdcSpecularMask(normalWS, viewDirectionWS,
                                       lightDirectionWS, lightMapRGB.b);
    float3 spec = float3(0.228274866938591, 0.21185337007045746,
                        0.2310815453529358) * 0.6000000238418579 * mask;
    return (baseSceneRGB + spec * diffuseRGB * litGate) * lightColorRGB;
}

// E1396:93-138. This in-material screen-depth edge light is enabled in-frame.
// It is distinct from an extruded outline draw and from the disabled base Fresnel.
// linearDepth = 1/(10239*deviceDepth + 1), a NORMALIZED depth, not world units.
// projectionScaleZ = cb1[0].z=1024. Returned offset uses captured screen UV.
float2 HertaHairRdcDepthRimOffset(float lightMapR, float3 normalWS,
    float3 viewDirectionWS, float linearDepth, float projectionScaleZ)
{
    float crossXZ = viewDirectionWS.z * normalWS.x - viewDirectionWS.x * normalWS.z;
    float side = crossXZ > 0.0 ? -1.0 : 1.0;
    return float2(side * lightMapR * 2.5 * 0.0055 /
                  (linearDepth * projectionScaleZ + 3.0), 0.0);
}

// E1396:139-177, with cb4[33].y=1, cb5[38].z=0, cb5[26].z=1.
// offsetLinearDepth comes from t6 at screenUV + HertaHairRdcDepthRimOffset.
float3 HertaHairRdcDepthRim(float3 rgb, float lightMapG, float3 normalWS,
    float3 viewDirectionWS, float3 lightDirectionWS,
    float linearDepth, float offsetLinearDepth)
{
    float depthDelta = max(offsetLinearDepth - linearDepth, 0.000001);
    float d = exp2(log2(depthDelta) * 0.014999999664723873);
    float edgeMask = HertaHairRdcSmooth01(saturate((d - 0.82) * 12.500003));
    edgeMask = edgeMask > 0.8999999761581421 ? edgeMask : 0.0;
    float3 edgeRGB = float3(0.575444221496582, 0.46112823486328125,
                           0.47621792554855347) * (0.5 * 2.5) * edgeMask;
    float halfLambert = saturate(dot(normalWS, lightDirectionWS) * 0.5 + 0.5);
    float illumination = 4.0 * lightMapG * halfLambert;
    float lightFactor = 1.0 + (illumination - 1.0) * 0.6000000238418579;
    float weight = saturate(lightFactor * (1.0 - dot(normalWS, viewDirectionWS)) *
                           dot(edgeRGB, float3(0.212671, 0.715160, 0.072169)));
    return lerp(rgb, edgeRGB, weight);
}

// E1396:178-203. At captured worldY>=.4 the height multiplier is identity.
float3 HertaHairRdcHeightMultiplier(float worldY)
{
    float bottom = 1.0 - HertaHairRdcSmooth01(saturate(worldY / 0.4000000059604645));
    float top = HertaHairRdcSmooth01(saturate((worldY - 0.20000000298023224) * 2.0));
    float middle = saturate(1.0 - bottom - top);
    return saturate(bottom * float3(0.3137255012989044, 0.3137255012989044,
                                   0.4901960790157318) * 0.5 +
                    (middle + top) * 0.5) * 2.0;
}

// E1396:200-257, 273. Intended for captured near range <=22 world units.
// Output is a signed correction, composed by Blend One One. Do not clamp it.
// E1396 cb3[0].z=0: the atmosphere branch is disabled in this frame.
float3 HertaHairRdcNearAdditionalDelta(float3 correctedRGB, float3 baseSceneRGB,
                                     float worldY)
{
    return correctedRGB * HertaHairRdcHeightMultiplier(worldY) *
           (1.0 + 0.019999999552965164) - baseSceneRGB;
}

#endif
