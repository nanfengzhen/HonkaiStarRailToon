using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace HertaRdc
{
    public sealed class HertaBodyFeature : ScriptableRendererFeature
    {
        public bool enableBodyAdditional = true;

        private static readonly int CharacterOriginId = Shader.PropertyToID("_CharacterOrigin");
        private static readonly int FaceLightDirectionId = Shader.PropertyToID("_FaceLightDirection");
        private readonly List<ActorDraw> actors = new List<ActorDraw>();
        private readonly HashSet<int> ambiguousInputs = new HashSet<int>();
        private MaterialPropertyBlock sourceBlock;
        private MaterialPropertyBlock targetBlock;
        private RTHandle baseScene;
        private BaseSceneCopyPass copyPass;
        private AdditionalPass additionalPass;

        public override void Create()
        {
            sourceBlock = new MaterialPropertyBlock();
            targetBlock = new MaterialPropertyBlock();
            copyPass = new BaseSceneCopyPass();
            additionalPass = new AdditionalPass(actors);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            actors.Clear();
            if (!AcceptCamera(renderingData.cameraData))
                return;

            Camera camera = renderingData.cameraData.camera;
            foreach (var input in Object.FindObjectsOfType<HertaFaceDepthInput>())
            {
                ActorDraw actor;
                if (!input.isActiveAndEnabled || !TryGetActor(input, camera, out actor))
                    continue;

                CopyFaceProperties(input.faceRenderer, actor.body);
                actors.Add(actor);
            }

            if (enableBodyAdditional && actors.Count != 0)
            {
                renderer.EnqueuePass(copyPass);
                renderer.EnqueuePass(additionalPass);
            }
        }

        public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
        {
            if (!enableBodyAdditional || !AcceptCamera(renderingData.cameraData) || actors.Count == 0)
                return;

            RenderTextureDescriptor descriptor = renderingData.cameraData.cameraTargetDescriptor;
            descriptor.graphicsFormat = GraphicsFormat.R16G16B16A16_SFloat;
            descriptor.depthBufferBits = 0;
            descriptor.depthStencilFormat = GraphicsFormat.None;
            descriptor.msaaSamples = 1;
            descriptor.bindMS = false;
            descriptor.useMipMap = false;
            descriptor.autoGenerateMips = false;
            descriptor.memoryless = RenderTextureMemoryless.None;
            RenderingUtils.ReAllocateIfNeeded(ref baseScene, descriptor, FilterMode.Point,
                TextureWrapMode.Clamp, name: "_HertaBodyBaseSceneCopy");

            RTHandle color = renderer.cameraColorTargetHandle;
            RTHandle depth = renderer.cameraDepthTargetHandle;
            copyPass.SetTargets(color, baseScene);
            additionalPass.SetTargets(color, depth, baseScene);
        }

        protected override void Dispose(bool disposing)
        {
            if (copyPass != null)
                copyPass.Dispose();
            if (additionalPass != null)
                additionalPass.Dispose();
            baseScene?.Release();
            baseScene = null;
            actors.Clear();
            ambiguousInputs.Clear();
        }

        private static bool AcceptCamera(in CameraData cameraData)
        {
            return cameraData.renderType == CameraRenderType.Base &&
                (cameraData.cameraType == CameraType.Game || cameraData.cameraType == CameraType.SceneView);
        }

        private bool TryGetActor(HertaFaceDepthInput input, Camera camera, out ActorDraw actor)
        {
            actor = default;
            if (input.faceRenderer == null)
                return false;

            SkinnedMeshRenderer body = null;
            foreach (var candidate in input.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                Mesh mesh = candidate.sharedMesh;
                if (candidate.name != "Body" || mesh == null || mesh.subMeshCount != 2 ||
                    mesh.GetIndexCount(0) != 32367 || mesh.GetIndexCount(1) != 38736)
                    continue;
                if (body != null)
                {
                    if (ambiguousInputs.Add(input.GetInstanceID()))
                        Debug.LogWarning("Herta Body: multiple Body renderers match the two submesh index counts; skipping this actor.", input);
                    return false;
                }
                body = candidate;
            }
            if (body == null || !body.enabled || body.forceRenderingOff ||
                !body.gameObject.activeInHierarchy ||
                (camera.cullingMask & (1 << body.gameObject.layer)) == 0)
                return false;

            Material[] materials = body.sharedMaterials;
            if (materials.Length != 2 || !IsBodyMaterial(materials[0]) || !IsBodyMaterial(materials[1]))
                return false;

            actor = new ActorDraw { body = body, bodyD = materials[0], bodyS = materials[1] };
            return true;
        }

        private static bool IsBodyMaterial(Material material)
        {
            return material != null && material.shader != null &&
                material.shader.name == "Herta/RDC/Body" && material.passCount >= 2 &&
                material.FindPass("HertaBodyAdditional") == 1;
        }

        private void CopyFaceProperties(SkinnedMeshRenderer face, SkinnedMeshRenderer body)
        {
            sourceBlock.Clear();
            face.GetPropertyBlock(sourceBlock, 0);
            for (int slot = 0; slot < 2; ++slot)
            {
                targetBlock.Clear();
                body.GetPropertyBlock(targetBlock, slot);
                targetBlock.SetVector(CharacterOriginId, sourceBlock.GetVector(CharacterOriginId));
                targetBlock.SetVector(FaceLightDirectionId, sourceBlock.GetVector(FaceLightDirectionId));
                body.SetPropertyBlock(targetBlock, slot);
            }
        }

        private struct ActorDraw
        {
            public SkinnedMeshRenderer body;
            public Material bodyD, bodyS;
        }

        private sealed class BaseSceneCopyPass : ScriptableRenderPass
        {
            private static readonly int BaseSceneId = Shader.PropertyToID("_HertaBodyBaseScene");
            private static readonly int BaseSceneScaleId = Shader.PropertyToID("_HertaBodyBaseSceneScale");
            private RTHandle color, destination;

            public BaseSceneCopyPass()
            {
                renderPassEvent = (RenderPassEvent)((int)RenderPassEvent.AfterRenderingOpaques + 1);
            }

            public void SetTargets(RTHandle color, RTHandle destination)
            {
                this.color = color;
                this.destination = destination;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                ConfigureTarget(destination);
                ConfigureClear(ClearFlag.None, Color.black);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                if (color == null || destination == null)
                    return;

                CommandBuffer cmd = CommandBufferPool.Get("Herta body base color snapshot");
                try
                {
                    Blitter.BlitCameraTexture(cmd, color, destination);
                    cmd.SetGlobalTexture(BaseSceneId, destination.nameID);
                    Vector4 scale = destination.useScaling
                        ? destination.rtHandleProperties.rtHandleScale
                        : Vector4.one;
                    cmd.SetGlobalVector(BaseSceneScaleId, new Vector4(scale.x, scale.y, 0f, 0f));
                    context.ExecuteCommandBuffer(cmd);
                }
                finally
                {
                    CommandBufferPool.Release(cmd);
                }
            }

            public void Dispose()
            {
                color = null;
                destination = null;
            }
        }

        private sealed class AdditionalPass : ScriptableRenderPass
        {
            private readonly List<ActorDraw> actors;
            private RTHandle color, depth, baseScene;

            public AdditionalPass(List<ActorDraw> actors)
            {
                this.actors = actors;
                renderPassEvent = (RenderPassEvent)((int)RenderPassEvent.AfterRenderingOpaques + 2);
                ConfigureInput(ScriptableRenderPassInput.Depth);
            }

            public void SetTargets(RTHandle color, RTHandle depth, RTHandle baseScene)
            {
                this.color = color;
                this.depth = depth;
                this.baseScene = baseScene;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                ConfigureTarget(color, depth);
                ConfigureClear(ClearFlag.None, Color.black);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                if (color == null || depth == null || baseScene == null)
                    return;

                CommandBuffer cmd = CommandBufferPool.Get("Herta body additional correction");
                try
                {
                    foreach (var actor in actors)
                    {
                        // Captured E1514 (single-sided) precedes E1537 (double-sided).
                        cmd.DrawRenderer(actor.body, actor.bodyS, 1, 1);
                        cmd.DrawRenderer(actor.body, actor.bodyD, 0, 1);
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
                color = null;
                depth = null;
                baseScene = null;
            }
        }
    }
}