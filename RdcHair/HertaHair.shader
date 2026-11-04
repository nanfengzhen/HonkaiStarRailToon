Shader "Herta/RDC/Hair"
{
    Properties
    {
        [MainTexture] _BaseMap("Hair Color",2D)="white"{}
        _LightMap("Hair Control (R edge, G diffuse, B specular)",2D)="white"{}
        _ColdRamp("Captured Ramp (t4 / Warm_Ramp asset)",2D)="white"{}
        _WarmRamp("Alternate Ramp (t3 / Cool_Ramp asset)",2D)="white"{}
        [Toggle] _UseSceneLight("Use Scene Main Light Direction",Float)=1
        [Toggle] _ReceiveSceneShadows("Receive Scene Main Light Shadows",Float)=1
        _SceneShadowFloor("Scene Shadow Minimum Brightness",Range(0.05,1))=0.4
        [HideInInspector] _Cull("Shadow Culling",Float)=2
        [HideInInspector] _FaceLightDirection("Capture Light",Vector)=(-.380356461,.435889959,.815676987,0)
        [HideInInspector] _HeadAxisX("Head X",Vector)=(0,-1,0,0)
        [HideInInspector] _HeadAxisY("Head Y",Vector)=(0,0,1,0)
        [HideInInspector] _HeadAxisZ("Head Z",Vector)=(-1,0,0,0)
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
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "HertaHairRdc.hlsl"
        #include "OutlineRdc.hlsl"
        TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
        TEXTURE2D(_LightMap); SAMPLER(sampler_LightMap);
        TEXTURE2D(_ColdRamp); SAMPLER(sampler_ColdRamp);
        TEXTURE2D_X(_HertaHairBaseScene); SAMPLER(sampler_HertaHairBaseScene);
        float4 _HertaHairBaseSceneScale;
        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _HeadAxisX,_HeadAxisY,_HeadAxisZ,_CharacterOrigin,_FaceLightDirection;
            float _UseSceneLight,_ReceiveSceneShadows,_SceneShadowFloor;
        CBUFFER_END
        struct Attributes
        {
            float4 positionOS:POSITION;
            float3 normalOS:NORMAL;
            float2 uv:TEXCOORD0;
        };
        struct Varyings
        {
            float4 positionCS:SV_POSITION;
            float3 positionWS:TEXCOORD0;
            float3 normalWS:TEXCOORD1;
            float2 uv:TEXCOORD2;
            float q:TEXCOORD3;
        };
        float3 HairLight(){return _UseSceneLight>.5?GetMainLight().direction:_FaceLightDirection.xyz;}
        Varyings HairVert(Attributes a)
        {
            Varyings o;
            o.positionWS=TransformObjectToWorld(a.positionOS.xyz);
            o.positionCS=TransformWorldToHClip(o.positionWS);
            o.normalWS=TransformObjectToWorldNormal(a.normalOS);
            o.uv=TRANSFORM_TEX(a.uv,_BaseMap);
            float3 v=GetCameraPositionWS()-o.positionWS;
            float3 localView=normalize(float3(dot(v,_HeadAxisX.xyz),dot(v,_HeadAxisY.xyz),dot(v,_HeadAxisZ.xyz)));
            o.q=dot(localView.xy,float2(.276,.961));
            return o;
        }
        float4 HairColor(Varyings i,bool localAlpha)
        {
            float4 d=SAMPLE_TEXTURE2D(_BaseMap,sampler_BaseMap,i.uv);
            float4 m=SAMPLE_TEXTURE2D(_LightMap,sampler_LightMap,i.uv);
            float2 rampUV=HertaHairRdcRampUV(normalize(i.normalWS),HairLight(),m.g);
            float3 ramp=SAMPLE_TEXTURE2D(_ColdRamp,sampler_ColdRamp,rampUV).rgb;
            float sceneShadow=HertaSceneShadowMultiplier(i.positionWS,
                _ReceiveSceneShadows,_SceneShadowFloor);
            return float4(HertaHairRdcBaseRGB(d.rgb,ramp)*sceneShadow,
                localAlpha?HertaHairRdcLocalAlpha(i.q,d.a):1);
        }
        float4 HairOpaque(Varyings i):SV_Target{return HairColor(i,false);}
        float4 HairAlpha(Varyings i):SV_Target{return HairColor(i,true);}
        float4 HairSpecular(Varyings i):SV_Target
        {
            float2 uv=GetNormalizedScreenSpaceUV(i.positionCS)*_HertaHairBaseSceneScale.xy;
            float3 baseScene=SAMPLE_TEXTURE2D_X(_HertaHairBaseScene,sampler_HertaHairBaseScene,uv).rgb;
            float sceneShadow=HertaSceneShadowMultiplier(i.positionWS,
                _ReceiveSceneShadows,_SceneShadowFloor);
            float3 d=SAMPLE_TEXTURE2D(_BaseMap,sampler_BaseMap,i.uv).rgb;
            float3 m=SAMPLE_TEXTURE2D(_LightMap,sampler_LightMap,i.uv).rgb;
            // Captured main-light color is white. Preserve that material response
            // while the scene main light supplies the interactive direction.
            float3 corrected=HertaHairRdcAdditionalBeforeDepthRim(baseScene/sceneShadow,d,m,normalize(i.normalWS),
                normalize(GetCameraPositionWS()-i.positionWS),HairLight(),1.0.xxx);
            float3 N=normalize(i.normalWS);
            float3 V=normalize(GetCameraPositionWS()-i.positionWS);
            float2 depthUV=GetNormalizedScreenSpaceUV(i.positionCS);
            float currentDepth=Linear01Depth(SampleSceneDepth(depthUV),_ZBufferParams);
            float2 edgeUV=HertaRimDepthUV(depthUV,currentDepth,_ProjectionParams.z,
                N,V,m.r,1.0,2.5,float4(0,0,0,1));
            float edgeDepth=Linear01Depth(SampleSceneDepth(edgeUV),_ZBufferParams);
            corrected=HertaHairDepthRimCurrentFrame(corrected,float4(m,0),
                N,V,HairLight(),currentDepth,edgeDepth);
            return float4(HertaHairRdcNearAdditionalDelta(corrected,baseScene/sceneShadow,
                i.positionWS.y-_CharacterOrigin.y)*sceneShadow,0);
        }
        ENDHLSL
        Pass
        {
            Name "HairOpaque" Tags{"LightMode"="HertaHairOpaque"}
            Cull Back ZWrite On ZTest LEqual Blend One Zero
            Stencil{Ref 17 ReadMask 255 WriteMask 0 Comp NotEqual Pass Replace Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex HairVert
            #pragma fragment HairOpaque
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            ENDHLSL
        }
        Pass
        {
            Name "HairLocalAlpha" Tags{"LightMode"="HertaHairLocalAlpha"}
            Cull Back ZWrite On ZTest LEqual Blend SrcAlpha OneMinusSrcAlpha ColorMask RGB
            Stencil{Ref 17 ReadMask 255 WriteMask 254 Comp Equal Pass Replace Fail Replace ZFail Keep}
            HLSLPROGRAM
            #pragma vertex HairVert
            #pragma fragment HairAlpha
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            ENDHLSL
        }
        Pass
        {
            Name "HairAdditional" Tags{"LightMode"="HertaHairAdditional"}
            Cull Back ZWrite Off ZTest LEqual Blend One One ColorMask RGB
            Stencil{Ref 1 ReadMask 255 WriteMask 255 Comp Always Pass Keep Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex HairVert
            #pragma fragment HairSpecular
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            ENDHLSL
        }
        UsePass "Hidden/Herta/SceneShadowCaster/ShadowCaster"
    }
}
