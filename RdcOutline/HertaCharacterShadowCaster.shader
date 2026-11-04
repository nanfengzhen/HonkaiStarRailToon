Shader "Hidden/Herta/CharacterShadowCaster"
{
    Properties
    {
        [Enum(UnityEngine.Rendering.CullMode)] _HertaShadowCasterCull("Caster culling", Float) = 2
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" }
        Pass
        {
            Name "HertaCharacterShadowCaster"
            Cull [_HertaShadowCasterCull]
            ZWrite On
            ZTest LEqual
            ColorMask 0
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex ShadowVertex
            #pragma fragment ShadowFragment
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            float4x4 _HertaWorldToCharacterShadowUVZ;
            float _HertaShadowCasterNormalOffset;
            CBUFFER_START(UnityPerMaterial)
                float _HertaShadowCasterCull;
            CBUFFER_END
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };
            float4 ShadowVertex(Attributes input) : SV_POSITION
            {
                // DrawRenderer supplies the live skinned geometry and renderer
                // transform. Do not BakeMesh or replace it with a bind-pose mesh.
                float3 p = TransformObjectToWorld(input.positionOS.xyz);
                p += TransformObjectToWorldNormal(input.normalOS) * _HertaShadowCasterNormalOffset;
                float4 q = mul(_HertaWorldToCharacterShadowUVZ, float4(p, 1.0));
                float4 clip = float4(2.0 * q.xy - q.ww, q.zw);
                // q.xy is already texture UV. Undo only the backend viewport
                // conversion; no camera view/projection globals are modified.
                #if UNITY_UV_STARTS_AT_TOP
                    clip.y = -clip.y;
                #endif
                if (UNITY_NEAR_CLIP_VALUE < 0.0)
                    clip.z = 2.0 * q.z - q.w;
                return clip;
            }
            float4 ShadowFragment() : SV_Target { return 0; }
            ENDHLSL
        }
    }
}
