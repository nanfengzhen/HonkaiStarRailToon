#ifndef HERTA_BODY_VIEW_EDGE_RDC_INCLUDED
#define HERTA_BODY_VIEW_EDGE_RDC_INCLUDED

// Frame 3745, EID 722 / 744. PS722 201-205 and 467-497;
// PS744 208-212 and 474-504. This is the BASE-pass view-edge tint.
// The additional-pass depth rim is a separate operation using LUT rows 3/4.
// Material LUT is a linear RGBA16F texture; use integer Load, no sampler.
float3 HertaBodyViewEdgeCurrentFrame(
    Texture2D<float4> materialLut, float3 colorBeforeViewEdge,
    uint materialID, float3 orientedUnitNormalWS,
    float3 cameraMinusPositionWS)
{
    // Caller uses the selected face UV for materialID and flips the normal
    // once on back faces. cb4[44].xyz=0, so the captured view-space offset
    // is absent and the N.V product is invariant under the view rotation.
    float ndotv = saturate(dot(orientedUnitNormalWS,
                              normalize(cameraMinusPositionWS)));

    // cb4[161].x has integer bit pattern 1: the LUT branch IS enabled.
    // Row5 RGB = tint; row6 R = edge scale; row6 G = edge threshold.
    // Row6 B belongs to additional-pass gain and must not enter this term.
    float3 edgeColor = materialLut.Load(int3((int)materialID, 5, 0)).rgb;
    float2 edgeParameters = materialLut.Load(int3((int)materialID, 6, 0)).rg;

    // PS722 479-491. Captured exponent cb4[42].z=1.
    float edge = saturate(max(1.0 - ndotv, 0.001) * edgeParameters.x);
    float edgeRamp = saturate((edge - edgeParameters.y)
                             / (1.0 - edgeParameters.y));
    edgeRamp = edgeRamp * edgeRamp * (3.0 - 2.0 * edgeRamp);

    // cb5[31]=(1,1,1,0.501960813999176), cb4[42].w=1,
    // cb5[32].x=1. The factor 0.25 and final signed tint are intentional.
    // This darkens ID6 with a relative blue bias; it is not additive light.
    float3 tint = edgeColor * 0.501960813999176;
    return colorBeforeViewEdge
        * (1.0 + (0.25 * edgeRamp) * (2.0 * tint - 1.0));
}

#endif
