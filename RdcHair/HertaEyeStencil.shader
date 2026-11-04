Shader "Herta/RDC/EyeStencil"
{
    Properties
    {
        _FaceMap("Face Control (G eye stencil)",2D)="white"{}
    }
    SubShader
    {
        Tags{"RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" "Queue"="Geometry"}
        HLSLINCLUDE
        #pragma target 4.5
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        TEXTURE2D(_FaceMap); SAMPLER(sampler_FaceMap);
        struct Attributes{float4 positionOS:POSITION;float2 uv1:TEXCOORD1;};
        struct Varyings{float4 positionCS:SV_POSITION;float2 uv:TEXCOORD0;};
        Varyings EyeVert(Attributes a){Varyings o;o.positionCS=TransformObjectToHClip(a.positionOS.xyz);o.uv=a.uv1;return o;}
        float4 Zero(Varyings i):SV_Target{return 0;}
        float4 Mark(Varyings i):SV_Target{clip(SAMPLE_TEXTURE2D(_FaceMap,sampler_FaceMap,i.uv).g-.5);return 0;}
        float4 Identity(Varyings i):SV_Target{return float4(1,1,1,0);}
        float4 Tint(Varyings i):SV_Target{return float4(.4160187840,.4534366727,.6070303917,0);}
        ENDHLSL
        Pass
        {
            Name "FaceBaselineStencil" Tags{"LightMode"="HertaFaceBaselineStencil"}
            Cull Back ZWrite On ZTest LEqual ColorMask 0
            Stencil{Ref 16 ReadMask 255 WriteMask 254 Comp Always Pass Replace Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex EyeVert
            #pragma fragment Zero
            ENDHLSL
        }
        Pass
        {
            Name "EyeStencil" Tags{"LightMode"="HertaEyeStencil"}
            Cull Back ZWrite On ZTest LEqual ColorMask 0
            Stencil{Ref 17 ReadMask 255 WriteMask 255 Comp Always Pass Replace Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex EyeVert
            #pragma fragment Mark
            ENDHLSL
        }
        Pass
        {
            Name "MaskReset" Tags{"LightMode"="HertaMaskReset"}
            Cull Back ZWrite On ZTest LEqual Blend One Zero
            Stencil{Ref 0 ReadMask 255 WriteMask 255 Comp Always Pass Replace Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex EyeVert
            #pragma fragment Zero
            ENDHLSL
        }
        Pass
        {
            Name "EyeIdentity" Tags{"LightMode"="HertaEyeIdentity"}
            Cull Back ZWrite Off ZTest LEqual Blend DstColor Zero ColorMask RGB
            HLSLPROGRAM
            #pragma vertex EyeVert
            #pragma fragment Identity
            ENDHLSL
        }
        Pass
        {
            Name "EyeTint" Tags{"LightMode"="HertaEyeTint"}
            Cull Back ZWrite Off ZTest LEqual Blend DstColor Zero ColorMask RGB
            Stencil{Ref 17 ReadMask 255 WriteMask 255 Comp Equal Pass Keep Fail Keep ZFail Keep}
            HLSLPROGRAM
            #pragma vertex EyeVert
            #pragma fragment Tint
            ENDHLSL
        }
    }
}


