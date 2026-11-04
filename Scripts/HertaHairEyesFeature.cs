using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace HertaRdc
{
    public sealed class HertaHairEyesFeature : ScriptableRendererFeature
    {
        public bool enableEyeOverlay = true;
        public bool enableHairSpecular = true;

        private readonly List<ActorDraw> actors = new List<ActorDraw>();
        private BasePass basePass;
        private SpecularPass specularPass;

        public override void Create()
        {
            if (basePass != null)
                basePass.Dispose();
            basePass = new BasePass(actors);
            specularPass = new SpecularPass(actors, basePass);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            actors.Clear();
            if (!AcceptCamera(renderingData.cameraData))
                return;

            Camera camera = renderingData.cameraData.camera;
            // Unity returns these in instance-ID order. The existing component is
            // the actor reference; no extra scene registration component is needed.
            var inputs = Object.FindObjectsOfType<HertaFaceDepthInput>();
            foreach (var input in inputs)
            {
                ActorDraw actor;
                if (input.isActiveAndEnabled && TryGetActor(input, camera, out actor))
                    actors.Add(actor);
            }
            if (actors.Count == 0)
                return;

            basePass.eyeOverlay = enableEyeOverlay;
            basePass.copyScene = enableHairSpecular;
            renderer.EnqueuePass(basePass);
            if (enableHairSpecular)
                renderer.EnqueuePass(specularPass);
        }

        public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
        {
            if (!AcceptCamera(renderingData.cameraData) || actors.Count == 0)
                return;
            // URP 14 exposes allocated camera attachments here, not in AddRenderPasses.
            basePass.SetTargets(renderer.cameraColorTargetHandle, renderer.cameraDepthTargetHandle);
            specularPass.SetTargets(renderer.cameraColorTargetHandle, renderer.cameraDepthTargetHandle);
        }

        protected override void Dispose(bool disposing)
        {
            if (basePass != null)
                basePass.Dispose();
            actors.Clear();
        }

        private static bool AcceptCamera(in CameraData cameraData)
        {
            return cameraData.renderType == CameraRenderType.Base &&
                (cameraData.cameraType == CameraType.Game || cameraData.cameraType == CameraType.SceneView);
        }

        private static bool CanDraw(SkinnedMeshRenderer renderer, Camera camera)
        {
            return renderer != null && renderer.enabled && !renderer.forceRenderingOff &&
                renderer.gameObject.activeInHierarchy && renderer.sharedMesh != null &&
                (camera.cullingMask & (1 << renderer.gameObject.layer)) != 0;
        }

        private static bool TryGetActor(HertaFaceDepthInput input, Camera camera, out ActorDraw actor)
        {
            actor = default;
            SkinnedMeshRenderer face = input.faceRenderer;
            SkinnedMeshRenderer hair = input.hairRenderer;
            if (!CanDraw(face, camera) || !CanDraw(hair, camera) ||
                face.sharedMesh.subMeshCount < 2 || hair.sharedMesh.subMeshCount < 1)
                return false;

            Material[] faceMaterials = face.sharedMaterials;
            Material[] hairMaterials = hair.sharedMaterials;
            if (faceMaterials.Length < 2 || hairMaterials.Length < 1)
                return false;
            Material eyes = faceMaterials[1];
            Material hairMaterial = hairMaterials[0];
            if (!IsMaterial(eyes, "Herta/RDC/EyeStencil", 5) ||
                !IsMaterial(hairMaterial, "Herta/RDC/Hair", 3))
                return false;

            SkinnedMeshRenderer mask = null;
            foreach (var candidate in input.GetComponentsInChildren<SkinnedMeshRenderer>())
            {
                if (candidate.name != "Face_Mask" || !CanDraw(candidate, camera) ||
                    candidate.sharedMesh.subMeshCount != 1 || candidate.sharedMesh.GetIndexCount(0) != 168)
                    continue;
                // Ambiguous or unconfigured actors are skipped, never rebound to
                // a similarly named renderer elsewhere in the scene.
                if (mask != null)
                    return false;
                mask = candidate;
            }
            if (mask == null)
                return false;
            Material[] maskMaterials = mask.sharedMaterials;
            if (maskMaterials.Length == 0 || !IsMaterial(maskMaterials[0], "Herta/RDC/EyeStencil", 5))
                return false;

            actor = new ActorDraw { face = face, hair = hair, mask = mask,
                eyes = eyes, hairMaterial = hairMaterial, maskMaterial = maskMaterials[0] };
            return true;
        }

        private static bool IsMaterial(Material material, string shaderName, int passCount)
        {
            return material != null && material.shader != null &&
                material.shader.name == shaderName && material.passCount >= passCount;
        }

        private struct ActorDraw
        {
            public SkinnedMeshRenderer face, hair, mask;
            public Material eyes, hairMaterial, maskMaterial;
        }

        private sealed class BasePass : ScriptableRenderPass
        {
            private static readonly int[] HeadProperties =
            {
                Shader.PropertyToID("_HeadAxisX"), Shader.PropertyToID("_HeadAxisY"),
                Shader.PropertyToID("_HeadAxisZ"), Shader.PropertyToID("_CharacterOrigin"),
                Shader.PropertyToID("_FaceLightDirection")
            };
            private static readonly int BaseSceneId = Shader.PropertyToID("_HertaHairBaseScene");
            private static readonly int BaseSceneScaleId = Shader.PropertyToID("_HertaHairBaseSceneScale");
            private readonly List<ActorDraw> actors;
            private readonly MaterialPropertyBlock sourceBlock = new MaterialPropertyBlock();
            private readonly MaterialPropertyBlock targetBlock = new MaterialPropertyBlock();
            private RTHandle color, depth;
            public RTHandle scratch;
            public bool eyeOverlay, copyScene;

            public BasePass(List<ActorDraw> actors)
            {
                this.actors = actors;
                renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
                // Request an intermediate camera target for the HDR snapshot.
                // The camera's real depth/stencil attachment stays bound throughout.
                ConfigureInput(ScriptableRenderPassInput.Color | ScriptableRenderPassInput.Depth);
            }

            public void SetTargets(RTHandle color, RTHandle depth)
            {
                this.color = color;
                this.depth = depth;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                ConfigureTarget(color, depth);
                if (!copyScene)
                    return;
                RenderTextureDescriptor descriptor = renderingData.cameraData.cameraTargetDescriptor;
                descriptor.depthBufferBits = 0;
                descriptor.depthStencilFormat = GraphicsFormat.None;
                descriptor.msaaSamples = 1;
                descriptor.bindMS = false;
                descriptor.useMipMap = false;
                descriptor.autoGenerateMips = false;
                descriptor.memoryless = RenderTextureMemoryless.None;
                RenderingUtils.ReAllocateIfNeeded(ref scratch, descriptor, FilterMode.Bilinear,
                    TextureWrapMode.Clamp, name: "_HertaHairBaseSceneCopy");
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                if (color == null || depth == null)
                    return;
                CommandBuffer cmd = CommandBufferPool.Get("Herta eyes and hair base");
                try
                {
                    foreach (var actor in actors)
                    {
                        CopyHeadProperties(actor);
                        cmd.DrawRenderer(actor.face, actor.eyes, 0, 0); // Ref16 baseline; RGB unchanged.
                        if (eyeOverlay)
                        {
                            cmd.DrawRenderer(actor.face, actor.eyes, 0, 1); // E581: Ref17 eye region.
                            cmd.DrawRenderer(actor.mask, actor.maskMaterial, 0, 2); // E594: local reset.
                            cmd.DrawRenderer(actor.face, actor.eyes, 1, 3); // Identity multiply.
                            cmd.DrawRenderer(actor.face, actor.eyes, 1, 4); // Eye tint multiply.
                        }
                        cmd.DrawRenderer(actor.hair, actor.hairMaterial, 0, 0);
                        cmd.DrawRenderer(actor.hair, actor.hairMaterial, 0, 1);
                    }
                    if (copyScene && scratch != null)
                    {
                        // Preserve the current linear HDR result before the signed
                        // additive correction; never sample the active color target.
                        Blitter.BlitCameraTexture(cmd, color, scratch);
                        cmd.SetGlobalTexture(BaseSceneId, scratch.nameID);
                        Vector4 scale = scratch.useScaling ? scratch.rtHandleProperties.rtHandleScale : Vector4.one;
                        cmd.SetGlobalVector(BaseSceneScaleId, new Vector4(scale.x, scale.y, 0f, 0f));
                        // Blitter bound scratch. Restore both real camera attachments.
                        CoreUtils.SetRenderTarget(cmd, color, depth, ClearFlag.None);
                    }
                    context.ExecuteCommandBuffer(cmd);
                }
                finally
                {
                    CommandBufferPool.Release(cmd);
                }
            }

            private void CopyHeadProperties(ActorDraw actor)
            {
                sourceBlock.Clear();
                actor.face.GetPropertyBlock(sourceBlock, 0);
                CopyTo(actor.hair, 0);
                CopyTo(actor.face, 1);
            }

            private void CopyTo(Renderer renderer, int materialIndex)
            {
                targetBlock.Clear();
                renderer.GetPropertyBlock(targetBlock, materialIndex);
                foreach (int property in HeadProperties)
                    targetBlock.SetVector(property, sourceBlock.GetVector(property));
                renderer.SetPropertyBlock(targetBlock, materialIndex);
            }

            public void Dispose()
            {
                if (scratch != null)
                    scratch.Release();
                scratch = null;
            }
        }

        private sealed class SpecularPass : ScriptableRenderPass
        {
            private readonly List<ActorDraw> actors;
            private readonly BasePass basePass;
            private RTHandle color, depth;

            public SpecularPass(List<ActorDraw> actors, BasePass basePass)
            {
                this.actors = actors;
                this.basePass = basePass;
                // RDC E1396 follows both the base hair and geometric outlines.
                renderPassEvent = (RenderPassEvent)((int)RenderPassEvent.AfterRenderingOpaques + 2);
            }

            public void SetTargets(RTHandle color, RTHandle depth)
            {
                this.color = color;
                this.depth = depth;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                ConfigureTarget(color, depth);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                if (color == null || depth == null || basePass.scratch == null)
                    return;
                CommandBuffer cmd = CommandBufferPool.Get("Herta hair signed HDR correction");
                try
                {
                    foreach (var actor in actors)
                        cmd.DrawRenderer(actor.hair, actor.hairMaterial, 0, 2);
                    context.ExecuteCommandBuffer(cmd);
                }
                finally
                {
                    CommandBufferPool.Release(cmd);
                }
            }
        }
    }
}
