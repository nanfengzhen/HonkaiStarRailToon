#ifndef HERTA_SCENE_SHADOWS_INCLUDED
#define HERTA_SCENE_SHADOWS_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

// Scene receiving is a user-requested extension: the captured character disables
// this input. Use URP's main-light atlas, strength, PCF and distance fade.
float HertaSceneShadowVisibility(float3 positionWS)
{
    #if defined(MAIN_LIGHT_CALCULATE_SHADOWS)
        #if defined(_MAIN_LIGHT_SHADOWS_SCREEN)
            float4 shadowCoord = ComputeScreenPos(TransformWorldToHClip(positionWS));
        #else
            float4 shadowCoord = TransformWorldToShadowCoord(positionWS);
        #endif
        return lerp(MainLightRealtimeShadow(shadowCoord), 1.0,
            GetMainLightShadowFade(positionWS));
    #else
        return 1.0;
    #endif
}

float HertaSceneShadowMultiplier(float3 positionWS, float receiveShadows,
    float minimumBrightness)
{
    return lerp(1.0, lerp(minimumBrightness, 1.0,
        HertaSceneShadowVisibility(positionWS)), receiveShadows);
}

#endif
