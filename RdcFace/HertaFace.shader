Shader "Herta/RDC/Face"
{
    Properties
    {
        [MainTexture] _BaseMap("Face Color", 2D) = "white" {}
        _FaceMap("Face Control (R region, G stencil, B view mask, A SDF)", 2D) = "white" {}
        _ExpressionMap("Expression Control (strengths zero in capture)", 2D) = "black" {}
        [Toggle] _UseSceneLight("Use Scene Main Light Direction", Float) = 0
        [Toggle] _ReceiveSceneShadows("Receive Scene Main Light Shadows",Float)=1
        _SceneShadowFloor("Scene Shadow Minimum Brightness",Range(0.05,1))=0.4
        [HideInInspector] _Cull("Shadow Culling", Float) = 2
        [HideInInspector] _FaceLightDirection("Capture Light Direction", Vector) = (-0.380356461,0.435889959,0.815676987,0)
        [HideInInspector] _HeadAxisX("Head X", Vector) = (0,-1,0,0)
        [HideInInspector] _HeadAxisY("Head Y", Vector) = (0,0,1,0)
        [HideInInspector] _HeadAxisZ("Head Z", Vector) = (-1,0,0,0)
        [HideInInspector] _CharacterOrigin("Character Origin", Vector) = (0,0,0,0)
        [HideInInspector] _FaceDepthAvailable("Depth Available", Float) = 0
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" "Queue"="Geometry" }
        Pass
        {
            Name "FaceForward"
            Tags { "LightMode"="UniversalForwardOnly" }
            Cull Back ZWrite On ZTest LEqual Blend One Zero
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex FaceVert
            #pragma fragment FaceFrag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "../RdcOutline/HertaSceneShadows.hlsl"
            #include "HertaFaceRdc.hlsl"

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_FaceMap); SAMPLER(sampler_FaceMap);
            TEXTURE2D(_FaceScreenDepth); SAMPLER(sampler_FaceScreenDepth);
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _FaceLightDirection;
                float4 _HeadAxisX, _HeadAxisY, _HeadAxisZ, _CharacterOrigin;
                float _UseSceneLight, _FaceDepthAvailable;
                float _ReceiveSceneShadows,_SceneShadowFloor;
                float4x4 _FaceDepthVP;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                float2 uv1 : TEXCOORD1;
                float4 color : COLOR;
            };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
                float2 uv : TEXCOORD2;
                float3 sdf : TEXCOORD3;
                float colorG : TEXCOORD4;
            };
            float3 FaceLight()
            {
                return _UseSceneLight > 0.5 ? GetMainLight().direction : _FaceLightDirection.xyz;
            }
            Varyings FaceVert(Attributes input)
            {
                Varyings o;
                o.positionWS = TransformObjectToWorld(input.positionOS.xyz);
                o.positionCS = TransformWorldToHClip(o.positionWS);
                o.normalWS = TransformObjectToWorldNormal(input.normalOS);
                o.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                o.sdf = HertaFaceSdfCoordinates(input.uv1, FaceLight(),
                    _HeadAxisX.xyz, _HeadAxisY.xyz, _HeadAxisZ.xyz);
                o.colorG = input.color.g;
                return o;
            }
            float ScreenOcclusion(float3 positionWS, float3 lightDirection)
            {
                if (_FaceDepthAvailable < 0.5) return 1;
                float3 offsetDirection = normalize(float3(lightDirection.x,
                    max(lightDirection.y, 0.2), lightDirection.z));
                float4 p = mul(_FaceDepthVP, float4(positionWS, 1));
                float4 s = mul(_FaceDepthVP, float4(positionWS + 0.008 * offsetDirection, 1));
                float2 uv = float2(0.5 * lerp(s.x, p.x, 0.63) / s.w + 0.5,
                    -0.5 * s.y / s.w + 0.5);
                float depth = SAMPLE_TEXTURE2D_LOD(_FaceScreenDepth, sampler_FaceScreenDepth, uv, 0).r;
                return depth < p.z / p.w ? 1 : 0;
            }
            float4 FaceFrag(Varyings input) : SV_Target
            {
                float4 baseSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                float4 faceSdf = SAMPLE_TEXTURE2D(_FaceMap, sampler_FaceMap, input.sdf.xy);
                float region = SAMPLE_TEXTURE2D(_FaceMap, sampler_FaceMap, input.uv).r;
                float3 view = GetCameraPositionWS() - input.positionWS;
                float distanceToCamera = length(view);
                float3 color = HertaFaceColor(baseSample, faceSdf, region, input.sdf.z,
                    input.colorG, normalize(input.normalWS), view / distanceToCamera,
                    distanceToCamera, _HeadAxisY.xyz, FaceLight(),
                    ScreenOcclusion(input.positionWS, FaceLight()),
                    input.positionWS.y - _CharacterOrigin.y);
                // Opaque forward RGB. The original G-buffer alpha stored base R.
                return float4(color*HertaSceneShadowMultiplier(input.positionWS,
                    _ReceiveSceneShadows,_SceneShadowFloor), 1);
            }
            ENDHLSL
        }
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode"="DepthOnly" }
            Cull Back ZWrite On ZTest LEqual ColorMask 0
            HLSLPROGRAM
            #pragma vertex DepthVert
            #pragma fragment DepthFrag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            float4 DepthVert(float4 positionOS:POSITION):SV_POSITION { return TransformObjectToHClip(positionOS.xyz); }
            float4 DepthFrag():SV_Target { return 0; }
            ENDHLSL
        }
        UsePass "Hidden/Herta/SceneShadowCaster/ShadowCaster"
    }
}
