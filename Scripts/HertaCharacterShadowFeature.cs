using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace HertaRdc
{
    // URP 14. Uses the existing HertaFaceDepthInput to find the actor without
    // adding scene components or storing scene references in a renderer asset.
    public sealed class HertaCharacterShadowFeature : ScriptableRendererFeature
    {
        public enum ProjectionMode { FitToMainDirectionalLight, CapturedRelativeToActor }

        [Serializable]
        public sealed class Settings
        {
            [Tooltip("Assign Hidden/Herta/CharacterShadowCaster to retain it in builds.")]
            public Shader casterShader;
            [Tooltip("Empty selects the only active HertaFaceDepthInput. Otherwise match its GameObject name.")]
            public string actorName = "";
            public ProjectionMode projection = ProjectionMode.FitToMainDirectionalLight;
            [Min(0.001f)] public float worldBoundsPadding = 0.05f;
            [Tooltip("Caster raster bias is not yet recovered from the capture. Zero is a starting setting, not a verified original value.")]
            public float casterDepthBias = 0f;
            public float casterSlopeBias = 0f;
            [Tooltip("Optional caster normal offset in current world units; independent from the recovered receiver offset of .001.")]
            public float casterNormalOffset = 0f;
            [Tooltip("Root pose in the original captured world; identity matches the supplied capture coordinates.")]
            public Vector3 capturedRootPosition = Vector3.zero;
            public Vector3 capturedRootEuler = Vector3.zero;
            public Vector3 capturedRootScale = Vector3.one;
        }

        public Settings settings = new Settings();
        private ShadowPass pass;

        public override void Create()
        {
            pass?.Dispose();
            pass = new ShadowPass(settings);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            pass.Prepare(ref renderingData);
            // Also enqueue an empty pass for unsupported cameras, so a preceding
            // camera's global availability cannot leak into this camera.
            renderer.EnqueuePass(pass);
        }

        protected override void Dispose(bool disposing)
        {
            pass?.Dispose();
            pass = null;
            Shader.SetGlobalFloat("_HertaCharacterShadowEnabled", 0f);
        }

        private sealed class ShadowPass : ScriptableRenderPass
        {
            private const int Resolution = 1536;
            private static readonly int MapId = Shader.PropertyToID("_HertaCharacterShadowMap");
            private static readonly int MatrixId = Shader.PropertyToID("_HertaWorldToCharacterShadowUVZ");
            private static readonly int SizeId = Shader.PropertyToID("_HertaCharacterShadowTexelSize");
            private static readonly int AtlasId = Shader.PropertyToID("_HertaCharacterShadowAtlasST");
            private static readonly int EnabledId = Shader.PropertyToID("_HertaCharacterShadowEnabled");
            private static readonly int LightDirectionId = Shader.PropertyToID("_HertaCharacterLightDirection");
            private static readonly int OffsetId = Shader.PropertyToID("_HertaShadowCasterNormalOffset");
            private readonly Settings settings;
            private readonly List<Draw> draws = new List<Draw>(4);
            private Material cullBack, cullOff;
            private RTHandle map;
            private Matrix4x4 worldToShadow;
            private Vector3 lightDirection;
            private bool ready;
            private bool reportedAmbiguity;

            private struct Draw
            {
                public SkinnedMeshRenderer renderer;
                public int slot;
                public bool doubleSided;
            }

            public ShadowPass(Settings settings)
            {
                this.settings = settings;
                renderPassEvent = (RenderPassEvent)((int)RenderPassEvent.BeforeRenderingOpaques - 2);
            }

            public void Prepare(ref RenderingData renderingData)
            {
                ready = false;
                draws.Clear();
                CameraData cameraData = renderingData.cameraData;
                if (cameraData.renderType != CameraRenderType.Base || cameraData.xrRendering ||
                    (cameraData.cameraType != CameraType.Game && cameraData.cameraType != CameraType.SceneView) ||
                    settings.casterShader == null)
                    return;

                HertaFaceDepthInput actor = null;
                foreach (HertaFaceDepthInput input in UnityEngine.Object.FindObjectsOfType<HertaFaceDepthInput>())
                {
                    if (!input.isActiveAndEnabled ||
                        (!string.IsNullOrEmpty(settings.actorName) && input.name != settings.actorName)) continue;
                    if (actor != null)
                    {
                        if (!reportedAmbiguity)
                            Debug.LogError("Herta character shadow requires one actor. Set actorName to a unique HertaFaceDepthInput GameObject name.");
                        reportedAmbiguity = true;
                        return;
                    }
                    actor = input;
                }
                if (actor == null) return;
                reportedAmbiguity = false;

                SkinnedMeshRenderer body = null;
                foreach (SkinnedMeshRenderer candidate in actor.GetComponentsInChildren<SkinnedMeshRenderer>())
                {
                    if (candidate.name != "Body" || candidate.sharedMesh == null ||
                        candidate.sharedMesh.subMeshCount != 2) continue;
                    if (body != null) return;
                    body = candidate;
                }
                if (!CanDraw(body, cameraData.camera) || !CanDraw(actor.faceRenderer, cameraData.camera) ||
                    !CanDraw(actor.hairRenderer, cameraData.camera)) return;

                // Body slot 0 is double-sided; slot 1 is single-sided. Face slot 1
                // contains eye geometry and is not an extra face-shell caster.
                draws.Add(new Draw { renderer = body, slot = 0, doubleSided = true });
                draws.Add(new Draw { renderer = body, slot = 1 });
                draws.Add(new Draw { renderer = actor.faceRenderer, slot = 0 });
                draws.Add(new Draw { renderer = actor.hairRenderer, slot = 0 });

                int index = renderingData.lightData.mainLightIndex;
                if (index < 0 || renderingData.lightData.visibleLights[index].lightType != LightType.Directional)
                    return;
                Vector4 forward = renderingData.lightData.visibleLights[index].localToWorldMatrix.GetColumn(2);
                lightDirection = -new Vector3(forward.x, forward.y, forward.z).normalized;

                if (settings.projection == ProjectionMode.CapturedRelativeToActor)
                {
                    Matrix4x4 captureRoot = Matrix4x4.TRS(settings.capturedRootPosition,
                        Quaternion.Euler(settings.capturedRootEuler), settings.capturedRootScale);
                    worldToShadow = CapturedMatrix() * captureRoot * actor.transform.worldToLocalMatrix;
                    if (!SystemInfo.usesReversedZBuffer)
                        worldToShadow.SetRow(2, worldToShadow.GetRow(3) - worldToShadow.GetRow(2));
                }
                else
                {
                    worldToShadow = FitToLight(lightDirection);
                }
                EnsureMaterials();
                ready = true;
            }

            private static bool CanDraw(SkinnedMeshRenderer renderer, Camera camera)
            {
                return renderer != null && renderer.sharedMesh != null && renderer.sharedMesh.subMeshCount > 0 &&
                    renderer.enabled && !renderer.forceRenderingOff && renderer.gameObject.activeInHierarchy &&
                    (camera.cullingMask & (1 << renderer.gameObject.layer)) != 0;
            }

            private void EnsureMaterials()
            {
                if (cullBack != null && cullBack.shader == settings.casterShader) return;
                CoreUtils.Destroy(cullBack);
                CoreUtils.Destroy(cullOff);
                cullBack = CoreUtils.CreateEngineMaterial(settings.casterShader);
                cullOff = CoreUtils.CreateEngineMaterial(settings.casterShader);
                cullBack.SetFloat("_HertaShadowCasterCull", (float)CullMode.Back);
                cullOff.SetFloat("_HertaShadowCasterCull", (float)CullMode.Off);
            }

            private Matrix4x4 FitToLight(Vector3 z)
            {
                Vector3 up = Mathf.Abs(Vector3.Dot(z, Vector3.up)) > 0.99f ? Vector3.forward : Vector3.up;
                Vector3 x = Vector3.Cross(z, up).normalized;
                Vector3 y = Vector3.Cross(x, z).normalized;
                Vector3 min = new Vector3(float.PositiveInfinity, float.PositiveInfinity, float.PositiveInfinity);
                Vector3 max = new Vector3(float.NegativeInfinity, float.NegativeInfinity, float.NegativeInfinity);
                foreach (Draw draw in draws)
                {
                    Bounds bounds = draw.renderer.bounds;
                    for (int corner = 0; corner < 8; ++corner)
                    {
                        Vector3 p = bounds.center + Vector3.Scale(bounds.extents, new Vector3(
                            (corner & 1) == 0 ? -1f : 1f, (corner & 2) == 0 ? -1f : 1f, (corner & 4) == 0 ? -1f : 1f));
                        Vector3 q = new Vector3(Vector3.Dot(x, p), Vector3.Dot(y, p), Vector3.Dot(z, p));
                        min = Vector3.Min(min, q);
                        max = Vector3.Max(max, q);
                    }
                }
                Vector3 padding = Vector3.one * settings.worldBoundsPadding;
                min -= padding;
                max += padding;
                Vector3 size = max - min;
                Matrix4x4 result = Matrix4x4.identity;
                result.SetRow(0, AxisRow(x / size.x, -min.x / size.x));
                result.SetRow(1, AxisRow(y / size.y, -min.y / size.y));
                result.SetRow(2, SystemInfo.usesReversedZBuffer
                    ? AxisRow(z / size.z, -min.z / size.z)
                    : AxisRow(-z / size.z, max.z / size.z));
                return result;
            }

            private static Vector4 AxisRow(Vector3 axis, float offset)
            {
                return new Vector4(axis.x, axis.y, axis.z, offset);
            }

            private static Matrix4x4 CapturedMatrix()
            {
                Matrix4x4 m = Matrix4x4.identity;
                m.SetRow(0, new Vector4(-0.7951077223f, 0f, -0.0841468200f, 0.4675234556f));
                m.SetRow(1, new Vector4(0.0143924849f, 0.4541399479f, -0.1359953582f, 0.0552372336f));
                m.SetRow(2, new Vector4(-0.0357566364f, 0.1023095921f, 0.3378663361f, 0.3145322204f));
                return m;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                ResetTarget();
                ConfigureClear(ClearFlag.None, Color.black);
                if (!ready) return;
                var descriptor = new RenderTextureDescriptor(Resolution, Resolution)
                {
                    graphicsFormat = GraphicsFormat.None,
                    depthStencilFormat = GraphicsFormat.D16_UNorm,
                    shadowSamplingMode = ShadowSamplingMode.CompareDepths,
                    msaaSamples = 1,
                    volumeDepth = 1,
                    dimension = TextureDimension.Tex2D,
                    useMipMap = false,
                    autoGenerateMips = false,
                    useDynamicScale = false,
                    sRGB = false
                };
                RenderingUtils.ReAllocateIfNeeded(ref map, descriptor, FilterMode.Bilinear,
                    TextureWrapMode.Clamp, isShadowMap: true, name: "_HertaCharacterShadowMap");
                ConfigureTarget(map, map);
                ConfigureClear(ClearFlag.All, SystemInfo.usesReversedZBuffer ? Color.black : Color.white);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                CommandBuffer cmd = CommandBufferPool.Get("Herta live character shadow");
                try
                {
                    cmd.SetGlobalFloat(EnabledId, ready ? 1f : 0f);
                    if (ready)
                    {
                        cmd.SetViewport(new Rect(0f, 0f, Resolution, Resolution));
                        cmd.SetGlobalMatrix(MatrixId, worldToShadow);
                        cmd.SetGlobalVector(LightDirectionId, lightDirection);
                        cmd.SetGlobalFloat(OffsetId, settings.casterNormalOffset);
                        cmd.SetGlobalDepthBias(settings.casterDepthBias, settings.casterSlopeBias);
                        foreach (Draw draw in draws)
                            cmd.DrawRenderer(draw.renderer, draw.doubleSided ? cullOff : cullBack, draw.slot, 0);
                        cmd.SetGlobalDepthBias(0f, 0f);
                        cmd.SetGlobalTexture(MapId, map.nameID);
                        cmd.SetGlobalVector(SizeId, new Vector4(1f / Resolution, 1f / Resolution, Resolution, Resolution));
                        cmd.SetGlobalVector(AtlasId, new Vector4(1f, 1f, 0f, 0f));
                        cmd.SetViewport(renderingData.cameraData.camera.pixelRect);
                    }
                    context.ExecuteCommandBuffer(cmd);
                }
                finally
                {
                    CommandBufferPool.Release(cmd);
                }
            }

            public void Dispose()
            {
                map?.Release();
                map = null;
                CoreUtils.Destroy(cullBack);
                CoreUtils.Destroy(cullOff);
                cullBack = cullOff = null;
                draws.Clear();
            }
        }
    }
}
