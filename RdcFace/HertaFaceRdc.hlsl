#ifndef HERTA_FACE_RDC_INCLUDED
#define HERTA_FACE_RDC_INCLUDED

// EID 569 VS 57-85: retain the captured atan2 approximation because the
// SDF transition is only 0.0002 wide.
float HertaFaceAngle(float y, float x)
{
    float t = min(abs(x), abs(y)) / max(abs(x), abs(y));
    float t2 = t * t;
    float p = (((0.020835 * t2 - 0.085133) * t2 + 0.180141) * t2 - 0.330299) * t2 + 0.999866;
    float a = p * t;
    if (abs(x) < abs(y)) a = 1.570796 - a;
    if (x < 0) a -= 3.141593;
    if (min(x, y) < 0 && max(x, y) >= 0) a = -a;
    return a;
}

float3 HertaFaceSdfCoordinates(float2 uv, float3 lightDirection,
    float3 headX, float3 headY, float3 headZ)
{
    if (length(lightDirection) < 0.9) return float3(0, 1, 0);
    float3 q = normalize(float3(dot(lightDirection, headX),
        dot(lightDirection, headY), dot(lightDirection, headZ)));
    float x = 0.984810 * q.y + 0.173650 * q.z;
    float y = -0.173650 * q.y + 0.984810 * q.z;
    float a = HertaFaceAngle(y, x);
    if (a < 0) uv.x = 1 - uv.x;
    return float3(uv, clamp(abs(a) * 0.318310, 0.0001, 0.9999));
}

// EID 569 PS. Expression RGB strengths, the secondary light, dynamic face
// tint and additional rim color are zero in this capture.
float3 HertaFaceColor(float4 baseSample, float4 faceSdf, float region,
    float threshold, float vertexG, float3 normalWS, float3 viewDirection,
    float cameraDistance, float3 headY, float3 lightDirection,
    float screenOcclusion, float characterHeight)
{
    float3 c = baseSample.rgb;
    float alpha = baseSample.a;
    float viewShape = pow(max(dot(normalWS,
        float3(viewDirection.x, 0.5 * viewDirection.y, viewDirection.z)), 0.001), 40);
    if (faceSdf.b * viewShape > 0.1)
        c = float3(0.322969139, 0.087611385, 0.087611385);

    float distanceWeight = saturate((cameraDistance - 0.6) / 1.4);
    float g = vertexG < 0.95 ? vertexG : 0;
    if (g > 1.04 - 0.24 * distanceWeight)
        c = float3(0.260327309, 0.112220600, 0.112220600);

    c *= 1 + 0.6 * max((alpha - 0.8) / 0.2, 0);
    float upperRegion = region > 0.1 ? 1 : 0;
    float midRegion = region > 0.1 && region < 0.8 ? 1 : 0;
    float q = upperRegion - 0.5 * midRegion;
    float sdfLight = smoothstep(max(threshold - 0.0001, 0.0001),
        min(threshold + 0.0001, 0.9999), faceSdf.a);
    float elevation = saturate(dot(headY, lightDirection) + 1);
    float lift = smoothstep(0.49, 1, elevation);
    float regionFactor = 1 - q + q * q * lift;
    float3 shadowTint = lerp(float3(1, 0.782678306, 0.745404363),
        float3(0.896269381, 0.806952357, 0.840620577), upperRegion);
    float rawLit = screenOcclusion * sdfLight;
    float3 shade = lerp(shadowTint, 1.0.xxx, regionFactor * rawLit);
    shade = rawLit >= 0.01
        ? saturate((shade - 0.55) / 0.45 * 0.5 + 0.5)
        : saturate(shade / 1.1);
    float3 result = saturate(c * shade);
    result += c * (0.02 * (1 - midRegion));
    float secondAlpha = saturate((min(alpha / 0.8, 1) - 0.8) / 0.2);
    result = lerp(result, 0.6 * c, secondAlpha);
    result *= lerp(float3(0.313725501, 0.313725501, 0.490196079),
        1.0.xxx, smoothstep(0, 0.4, characterHeight));
    return result * 1.02;
}
#endif
