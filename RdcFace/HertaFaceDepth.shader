Shader "Hidden/Herta/FaceDepthInput"
{
    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" "RenderType" = "Opaque" }
        Pass
        {
            Name "FaceDepthInput"
            Tags { "LightMode" = "HertaFaceDepthInput" }
            Cull Back
            // EID 345 D3D11: slope bias -3, constant bias -1.
            // Unity reverses the logical bias for its reversed-Z projection.
            Offset 3, 1
            ZWrite On
            ZTest LEqual
            Blend Off
            ColorMask R

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            float4x4 _HertaFaceDepthDrawVP;

            struct Attributes
            {
                float3 positionOS : POSITION;
                float4 color : COLOR;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionCS = mul(_HertaFaceDepthDrawVP,
                    float4(TransformObjectToWorld(input.positionOS), 1));
                // EID 345 VS instruction 20-21. Normal offset and bit-mask
                // filtering are disabled by the captured constants.
                if (input.color.b > 0.9)
                    output.positionCS = float4(-99, -99, -99, 1);
                return output;
            }

            float4 Frag(Varyings input) : SV_Target
            {
                // Fragment SV_POSITION.z is already device depth on D3D11/12.
                return float4(input.positionCS.z, 0.0, 0.0, 1.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
