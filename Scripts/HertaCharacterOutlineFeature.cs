using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace HertaRdc
{
    public sealed class HertaCharacterOutlineFeature : ScriptableRendererFeature
    {
        public enum ExtrusionSource { MeshNormal, MeshTangentXYZ }

        [Tooltip("Assign Hidden/Herta/CharacterOutline so it is included in builds.")]
        public Shader outlineShader;
        public bool enableOutline = true;
        [Tooltip("RDC outline VS reads TANGENT.xyz (v2). Import the FBX authored tangents; do not recalculate Mikk tangents.")]
        public ExtrusionSource extrusionSource = ExtrusionSource.MeshTangentXYZ;

        private readonly List<ActorDraw> actors = new List<ActorDraw>();
        private Material material;
        private OutlinePass pass;
        private OutlinePass hairPass;

        public override void Create()
        {
            CoreUtils.Destroy(material);
            material = outlineShader != null ? CoreUtils.CreateEngineMaterial(outlineShader) : null;
            pass = new OutlinePass(actors, material, false);
            hairPass = new OutlinePass(actors, material, true);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            actors.Clear();
            if (!enableOutline || material == null || !AcceptCamera(renderingData.cameraData))
                return;
            Camera camera = renderingData.cameraData.camera;
            foreach (HertaFaceDepthInput input in Object.FindObjectsOfType<HertaFaceDepthInput>())
            {
                ActorDraw actor;
                if (input.isActiveAndEnabled && TryGetActor(input, camera, out actor))
                    actors.Add(actor);
            }
            if (actors.Count == 0)
                return;
            pass.directionSource = (float)extrusionSource;
            hairPass.directionSource = (float)extrusionSource;
            renderer.EnqueuePass(pass);
            renderer.EnqueuePass(hairPass);
        }

        public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
        {
            if (enableOutline && material != null && actors.Count != 0 && AcceptCamera(renderingData.cameraData))
            {
                pass.SetTargets(renderer.cameraColorTargetHandle, renderer.cameraDepthTargetHandle);
                hairPass.SetTargets(renderer.cameraColorTargetHandle, renderer.cameraDepthTargetHandle);
            }
        }

        protected override void Dispose(bool disposing)
        {
            CoreUtils.Destroy(material);
            material = null;
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
                face.sharedMesh.subMeshCount < 1 || face.sharedMesh.GetIndexCount(0) != 11664 ||
                hair.sharedMesh.subMeshCount != 1 || hair.sharedMesh.GetIndexCount(0) != 17937)
                return false;

            SkinnedMeshRenderer body = null;
            foreach (SkinnedMeshRenderer candidate in input.GetComponentsInChildren<SkinnedMeshRenderer>())
            {
                Mesh mesh = candidate.sharedMesh;
                if (candidate.name != "Body" || !CanDraw(candidate, camera) ||
                    mesh.subMeshCount != 2 || mesh.GetIndexCount(0) != 32367 || mesh.GetIndexCount(1) != 38736)
                    continue;
                if (body != null)
                    return false;
                body = candidate;
            }
            if (body == null)
                return false;
            Material[] bodyMaterials = body.sharedMaterials;
            if (bodyMaterials.Length != 2 || !HasBodyTextures(bodyMaterials[0]) || !HasBodyTextures(bodyMaterials[1]))
                return false;
            actor = new ActorDraw { face = face, hair = hair, body = body,
                bodyD = bodyMaterials[0], bodyS = bodyMaterials[1] };
            return true;
        }

        private static bool HasBodyTextures(Material source)
        {
            return source != null && source.HasProperty("_LightMap") && source.HasProperty("_MaterialLUT") &&
                source.GetTexture("_LightMap") != null && source.GetTexture("_MaterialLUT") != null;
        }

        private struct ActorDraw
        {
            public SkinnedMeshRenderer face, hair, body;
            public Material bodyD, bodyS;
        }

        private sealed class OutlinePass : ScriptableRenderPass
        {
            private static readonly int PartId = Shader.PropertyToID("_HertaOutlinePart");
            private static readonly int SourceId = Shader.PropertyToID("_HertaOutlineDirectionSource");
            private static readonly int OrthographicId = Shader.PropertyToID("_HertaOutlineOrthographic");
            private static readonly int LightMapId = Shader.PropertyToID("_HertaOutlineLightMap");
            private static readonly int LutId = Shader.PropertyToID("_HertaOutlineMaterialLUT");
            private static readonly int[] SourceAxes = {
                Shader.PropertyToID("_HeadAxisX"), Shader.PropertyToID("_HeadAxisY"), Shader.PropertyToID("_HeadAxisZ") };
            private static readonly int[] TargetAxes = {
                Shader.PropertyToID("_HertaOutlineHeadAxisX"), Shader.PropertyToID("_HertaOutlineHeadAxisY"),
                Shader.PropertyToID("_HertaOutlineHeadAxisZ") };
            private readonly List<ActorDraw> actors;
            private readonly Material material;
            private readonly bool hairOnly;
            private readonly MaterialPropertyBlock headProperties = new MaterialPropertyBlock();
            private RTHandle color, depth;
            public float directionSource;

            public OutlinePass(List<ActorDraw> actors, Material material, bool hairOnly)
            {
                this.actors = actors;
                this.material = material;
                this.hairOnly = hairOnly;
                // RDC hair outline E842 follows eye stencil and hair E658/680.
                // A hair hull drawn first writes depth in front of the eye surface,
                // preventing E581 from marking the covered eyelids for local alpha.
                // Keep face/body hulls before their bases: the double-sided cloth
                // base must cover zero-width, coplanar backfaces in this Forward port.
                renderPassEvent = hairOnly
                    ? (RenderPassEvent)((int)RenderPassEvent.AfterRenderingOpaques + 1)
                    : (RenderPassEvent)((int)RenderPassEvent.BeforeRenderingOpaques - 1);
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
                CommandBuffer cmd = CommandBufferPool.Get(hairOnly
                    ? "Herta hair outline after local alpha" : "Herta face and body outlines");
                try
                {
                    cmd.SetGlobalFloat(SourceId, directionSource);
                    cmd.SetGlobalFloat(OrthographicId, renderingData.cameraData.camera.orthographic ? 1f : 0f);
                    foreach (ActorDraw actor in actors)
                    {
                        headProperties.Clear();
                        actor.face.GetPropertyBlock(headProperties, 0);
                        for (int axis = 0; axis < 3; ++axis)
                            cmd.SetGlobalVector(TargetAxes[axis], headProperties.GetVector(SourceAxes[axis]));
                        if (hairOnly)
                        {
                            cmd.SetGlobalFloat(PartId, 1f);
                            cmd.DrawRenderer(actor.hair, material, 0, 1);
                        }
                        else
                        {
                            cmd.SetGlobalFloat(PartId, 0f);
                            cmd.DrawRenderer(actor.face, material, 0, 0);
                            cmd.SetGlobalFloat(PartId, 2f);
                            DrawBody(cmd, actor.body, actor.bodyS, 1);
                            DrawBody(cmd, actor.body, actor.bodyD, 0);
                        }
                    }
                    context.ExecuteCommandBuffer(cmd);
                }
                finally
                {
                    CommandBufferPool.Release(cmd);
                }
            }

            private void DrawBody(CommandBuffer cmd, SkinnedMeshRenderer body, Material source, int submesh)
            {
                cmd.SetGlobalTexture(LightMapId, source.GetTexture("_LightMap"));
                cmd.SetGlobalTexture(LutId, source.GetTexture("_MaterialLUT"));
                cmd.DrawRenderer(body, material, submesh, 2);
            }
        }
    }
}
