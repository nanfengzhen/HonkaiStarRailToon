Shader "Hidden/Herta/CharacterOutline"
{
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" }
        Cull Front ZWrite On ZTest LEqual Blend One Zero ColorMask RGBA

        HLSLINCLUDE
        #pragma target 4.5
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "OutlineRdc.hlsl"

        // Command-buffer globals are unique to this pass. Renderer property blocks
        // keep all existing face/hair/body properties unchanged.
        TEXTURE2D(_HertaOutlineLightMap); SAMPLER(sampler_HertaOutlineLightMap);
        TEXTURE2D(_HertaOutlineMaterialLUT);
        float _HertaOutlinePart;
        float _HertaOutlineDirectionSource;
        float _HertaOutlineOrthographic;
        float4 _HertaOutlineHeadAxisX, _HertaOutlineHeadAxisY, _HertaOutlineHeadAxisZ;

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS : NORMAL;
            float4 tangentOS : TANGENT;
            float2 uv0 : TEXCOORD0;
            float4 color : COLOR;
        };
        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float2 uv0 : TEXCOORD0;
        };

        Varyings OutlineVertex(Attributes input)
        {
            Varyings output;
            float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
            float3 positionVS = TransformWorldToView(positionWS);
            float3 originalPositionVS = positionVS;
            float3 cameraToVertex = GetCameraPositionWS() - positionWS;
            // RDC VS816/842/870/878 use TANGENT.xyz (v2) for extrusion.
            // FBX authored tangents carry this direction; Mikk tangents do not.
            float3 directionOS = _HertaOutlineDirectionSource > 0.5
                ? input.tangentOS.xyz : input.normalOS;
            float3 directionWS = mul(directionOS, (float3x3)GetWorldToObjectMatrix());
            float3 directionVS = mul((float3x3)GetWorldToViewMatrix(), directionWS);
            // Do not normalize directionVS before the helper replaces Z with -.1.
            float projectionYY = GetViewToHClipMatrix()[1][1];
            if (_HertaOutlinePart < 0.5)
            {
                // RDC face object coordinates follow the head bone. The existing
                // HertaFaceDirection component supplies the matching live axes.
                float3 viewHead = normalize(float3(
                    dot(cameraToVertex, _HertaOutlineHeadAxisX.xyz),
                    dot(cameraToVertex, _HertaOutlineHeadAxisY.xyz),
                    dot(cameraToVertex, _HertaOutlineHeadAxisZ.xyz)));
                positionVS = HertaFaceOutlineCurrentFrame(positionVS, directionVS,
                    input.color, viewHead, projectionYY, _HertaOutlineOrthographic > 0.5);
            }
            else
            {
                positionVS = HertaHairBodyOutlineCurrentFrame(positionVS, directionVS,
                    input.color, length(cameraToVertex), projectionYY,
                    _HertaOutlinePart > 1.5, _HertaOutlineOrthographic > 0.5);
            }
            // Preserve view-depth displacement. Altering clip.xy alone loses the
            // source -.1 extrusion and its depth overlap with the base geometry.
            // Match the base pass exactly when vertex alpha disables extrusion.
            // A separate view/projection product otherwise rounds coplanar inner
            // cloth to a different depth and makes the two passes fight.
            output.positionCS = TransformWorldToHClip(positionWS)
                + mul(GetViewToHClipMatrix(), float4(positionVS - originalPositionVS, 0.0));
            output.uv0 = input.uv0;
            return output;
        }

        float4 OutlineFragment(Varyings input) : SV_Target
        {
            float3 color;
            if (_HertaOutlinePart < 0.5)
                color = HertaFaceOutlineColorCurrentFrame();
            else if (_HertaOutlinePart < 1.5)
                color = HertaHairOutlineColorCurrentFrame();
            else
            {
                // PS870/878 use UV0 even for the original double-sided material.
                float alpha = SAMPLE_TEXTURE2D(_HertaOutlineLightMap,
                    sampler_HertaOutlineLightMap, input.uv0).a;
                color = HertaBodyOutlineColorCurrentFrame(_HertaOutlineMaterialLUT, alpha);
            }
            // These are already linear values. The source writes RGBA with A=0.
            return float4(color, 0.0);
        }
        ENDHLSL

        Pass
        {
            Name "FaceOutline"
            Tags { "LightMode"="HertaCharacterOutline" }
            Stencil { Ref 16 ReadMask 255 WriteMask 254 Comp Always Pass Replace }
            HLSLPROGRAM
            #pragma vertex OutlineVertex
            #pragma fragment OutlineFragment
            ENDHLSL
        }
        Pass
        {
            Name "HairOutline"
            Tags { "LightMode"="HertaCharacterOutline" }
            Stencil { Ref 17 ReadMask 255 WriteMask 254 Comp Always Pass Replace }
            HLSLPROGRAM
            #pragma vertex OutlineVertex
            #pragma fragment OutlineFragment
            ENDHLSL
        }
        Pass
        {
            Name "BodyOutline"
            Tags { "LightMode"="HertaCharacterOutline" }
            Stencil { Ref 16 ReadMask 255 WriteMask 255 Comp Always Pass Replace }
            HLSLPROGRAM
            #pragma vertex OutlineVertex
            #pragma fragment OutlineFragment
            ENDHLSL
        }
    }
}
