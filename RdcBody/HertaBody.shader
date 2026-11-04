Shader "Herta/RDC/Body"
{
    Properties
    {
        [MainTexture] _BaseMap("Body Color",2D)="white"{}
        _LightMap("Body LightMap (G lighting, B specular, A material ID)",2D)="white"{}
        _Ramp("Captured Ramp (t5 / Warm_Ramp asset)",2D)="white"{}
        _MixMask("Body Effect (captured sRGB view)",2D)="black"{}
        _Stockings("Captured linear BC7 stockings mask and detail",2D)="black"{}
        _MaterialLUT("RDC 8x8 RGBAHalf Material Parameters",2D)="black"{}
        [Toggle] _BodyViewEdgeEnabled("Captured Material View Tint",Float)=1
        _BodyFlowMap("Captured Flow Pattern (linear)",2D)="black"{}
        _BodyFlowNoise("Captured Flow Noise (sRGB)",2D)="black"{}
        [Toggle] _BodyFlowEnabled("Captured Clothing Flow",Float)=1
        [Toggle] _BodyFlowFreeze("Freeze Clothing Flow Time",Float)=0
        _BodyFlowTime("Frozen Flow Time (seconds)",Float)=39.89297866821289
        [Enum(UnityEngine.Rendering.CullMode)] _Cull("Culling",Float)=2
        [Toggle] _UseSceneLight("Use Scene Main Light Direction",Float)=1
        [Toggle] _ReceiveSceneShadows("Receive Scene Main Light Shadows",Float)=1
        _SceneShadowFloor("Scene Shadow Minimum Brightness",Range(0.05,1))=0.4
        [HideInInspector] _FaceLightDirection("Captured Light Direction",Vector)=(-.380356461,.435889959,.815676987,0)
        [HideInInspector] _CharacterOrigin("Character Origin",Vector)=(0,0,0,0)
    }
    SubShader
    {
        Tags{"RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" "Queue"="Geometry"}
        HLSLINCLUDE
        #pragma target 4.5
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
        #include "../RdcOutline/HertaSceneShadows.hlsl"
        #include "HertaBodyBaseRdc.hlsl"
        #include "HertaBodyAdditionalRdc.hlsl"
        #include "HertaBodyViewEdgeRdc.hlsl"
        #include "HertaBodyFlowRdc.hlsl"
        TEXTURE2D(_BaseMap);SAMPLER(sampler_BaseMap);
        TEXTURE2D(_LightMap);SAMPLER(sampler_LightMap);
        TEXTURE2D(_Ramp);SAMPLER(sampler_Ramp);
        TEXTURE2D(_MixMask);SAMPLER(sampler_MixMask);
        TEXTURE2D(_MaterialLUT);
        TEXTURE2D(_Stockings);SAMPLER(sampler_Stockings);
        TEXTURE2D(_BodyFlowMap);SAMPLER(sampler_BodyFlowMap);
        TEXTURE2D(_BodyFlowNoise);SAMPLER(sampler_BodyFlowNoise);
        TEXTURE2D_X(_HertaBodyBaseScene);SAMPLER(sampler_HertaBodyBaseScene);
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        Texture2D<float> _HertaCharacterShadowMap;
        float4 _HertaBodyBaseSceneScale;
        float4x4 _HertaWorldToCharacterShadowUVZ;
        float4 _HertaCharacterShadowTexelSize,_HertaCharacterShadowAtlasST;
        float _HertaCharacterShadowEnabled;
        float4 _HertaCharacterLightDirection;
        CBUFFER_START(UnityPerMaterial)
            float4 _FaceLightDirection,_CharacterOrigin;
            float _Cull,_UseSceneLight,_ReceiveSceneShadows,_SceneShadowFloor;
            float _BodyViewEdgeEnabled,_BodyFlowEnabled,_BodyFlowFreeze,_BodyFlowTime;
        CBUFFER_END
        struct Attributes
        {
            float4 positionOS:POSITION;
            float3 normalOS:NORMAL;
            float2 uv0:TEXCOORD0;
            float2 uv1:TEXCOORD1;
            float4 color:COLOR;
        };
        struct Varyings
        {
            float4 positionCS:SV_POSITION;
            float3 positionWS:TEXCOORD0;
            float3 normalWS:TEXCOORD1;
            float2 uv0:TEXCOORD2;
            float2 uv1:TEXCOORD3;
            float vertexR:TEXCOORD4;
        };
        float3 BodyLight(){return _HertaCharacterShadowEnabled>.5?_HertaCharacterLightDirection.xyz:(_UseSceneLight>.5?GetMainLight().direction:_FaceLightDirection.xyz);}
        Varyings BodyVert(Attributes a)
        {
            Varyings o;
            o.positionWS=TransformObjectToWorld(a.positionOS.xyz);
            o.positionCS=TransformWorldToHClip(o.positionWS);
            o.normalWS=TransformObjectToWorldNormal(a.normalOS);
            o.uv0=a.uv0;
            o.uv1=a.uv1;
            o.vertexR=a.color.r;
            return o;
        }
        float4 BodyBase(Varyings i,bool frontFace:SV_IsFrontFace):SV_Target
        {
            float3 N=normalize(i.normalWS)*(frontFace?1.0:-1.0);
            float rawShadow=HertaCharacterShadowRaw(_HertaCharacterShadowMap,
                sampler_LinearClampCompare,i.positionWS,N,
                _HertaWorldToCharacterShadowUVZ,_HertaCharacterShadowAtlasST,
                _HertaCharacterShadowTexelSize,0.001,_HertaCharacterShadowEnabled);
            HertaBodyBaseResult b=HertaBodyEvaluateStage3(_BaseMap,sampler_BaseMap,
                _LightMap,sampler_LightMap,_Ramp,sampler_Ramp,_MixMask,sampler_MixMask,
                _Stockings,sampler_Stockings,i.uv0,i.uv1,i.vertexR,i.normalWS,
                frontFace,BodyLight(),GetCameraPositionWS()-i.positionWS,rawShadow);
            float3 viewTinted=HertaBodyViewEdgeCurrentFrame(_MaterialLUT,b.color,
                b.materialID,b.normalWS,GetCameraPositionWS()-i.positionWS);
            b.color=lerp(b.color,viewTinted,_BodyViewEdgeEnabled);
            return float4(b.color*HertaSceneShadowMultiplier(i.positionWS,
                _ReceiveSceneShadows,_SceneShadowFloor),1);
        }
        float4 BodyAdditional(Varyings i,bool frontFace:SV_IsFrontFace):SV_Target
        {
            float2 uv=frontFace?i.uv0:i.uv1;
            float4 selected=SAMPLE_TEXTURE2D(_BaseMap,sampler_BaseMap,uv);
            float3 layer=SAMPLE_TEXTURE2D(_BaseMap,sampler_BaseMap,i.uv0).rgb;
            float mask=SAMPLE_TEXTURE2D(_MixMask,sampler_MixMask,i.uv0).r;
            float3 mixed=HertaBodyMixedAlbedo(selected.rgb,layer,mask);
            float4 lightMap=SAMPLE_TEXTURE2D(_LightMap,sampler_LightMap,uv);
            float2 screenUV=GetNormalizedScreenSpaceUV(i.positionCS)*_HertaBodyBaseSceneScale.xy;
            float3 baseScene=SAMPLE_TEXTURE2D_X(_HertaBodyBaseScene,sampler_HertaBodyBaseScene,screenUV).rgb;
            float sceneShadow=HertaSceneShadowMultiplier(i.positionWS,
                _ReceiveSceneShadows,_SceneShadowFloor);
            float3 N=normalize(i.normalWS)*(frontFace?1.0:-1.0);
            float rawShadow=HertaCharacterShadowRaw(_HertaCharacterShadowMap,
                sampler_LinearClampCompare,i.positionWS,N,
                _HertaWorldToCharacterShadowUVZ,_HertaCharacterShadowAtlasST,
                _HertaCharacterShadowTexelSize,0.001,_HertaCharacterShadowEnabled);
            float currentLinear01=Linear01Depth(SampleSceneDepth(screenUV/
                _HertaBodyBaseSceneScale.xy),_ZBufferParams);
            float2 rimUV=HertaRimDepthUV(screenUV/_HertaBodyBaseSceneScale.xy,
                currentLinear01,_ProjectionParams.z,N,
                normalize(GetCameraPositionWS()-i.positionWS),lightMap.r,1.0,2.5,
                float4(0,0,0,1));
            float offsetLinear01=Linear01Depth(SampleSceneDepth(rimUV),_ZBufferParams);
            float3 target=HertaBodyStage3TargetBeforeDistanceFog(_MaterialLUT,
                baseScene/sceneShadow,selected,mixed,lightMap,i.normalWS,GetCameraPositionWS()-i.positionWS,
                frontFace,BodyLight(),1.0.xxx,rawShadow,i.positionWS.y,
                _CharacterOrigin.y,currentLinear01,offsetLinear01);
            float flowTime=HertaBodyFlowTime(_Time.y,_BodyFlowFreeze,_BodyFlowTime);
            float3 flow=HertaBodyFlowScreenCurrentFrame(_BodyFlowMap,sampler_BodyFlowMap,
                _BodyFlowNoise,sampler_BodyFlowNoise,GetNormalizedScreenSpaceUV(i.positionCS),
                length(GetCameraPositionWS()-i.positionWS),i.uv0,mask,flowTime);
            // E1514:466 adds emission after the height/LUT material terms.
            // Scene shadows affect the surface once; emission keeps its own color.
            return HertaBodySignedDelta(target*sceneShadow+flow*_BodyFlowEnabled,baseScene,1);
        }
        ENDHLSL
        Pass
        {
            Name "BodyBase" Tags{"LightMode"="UniversalForwardOnly"}
            Cull [_Cull] ZWrite On ZTest LEqual Blend One Zero
            Stencil{Ref 16 ReadMask 255 WriteMask 255 Comp Always Pass Replace Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex BodyVert
            #pragma fragment BodyBase
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            ENDHLSL
        }
        Pass
        {
            Name "HertaBodyAdditional" Tags{"LightMode"="HertaBodyAdditional"}
            Cull [_Cull] ZWrite Off ZTest Equal Blend One One ColorMask RGB
            Stencil{Ref 16 ReadMask 255 WriteMask 255 Comp Always Pass Keep Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex BodyVert
            #pragma fragment BodyAdditional
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            ENDHLSL
        }
        UsePass "Hidden/Herta/SceneShadowCaster/ShadowCaster"
    }
}
