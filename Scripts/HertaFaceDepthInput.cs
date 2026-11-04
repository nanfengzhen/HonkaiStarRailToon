using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;

[ExecuteAlways]
[DisallowMultipleComponent]
public sealed class HertaFaceDepthInput : MonoBehaviour
{
    public SkinnedMeshRenderer faceRenderer;
    [Tooltip("EID 345: only the hair mesh writes the face occlusion depth.")]
    public SkinnedMeshRenderer hairRenderer;

    [Tooltip("Optional externally owned depth material. Otherwise a temporary material uses depthShader.")]
    public Material depthMaterial;

    [Tooltip("Assign Hidden/Herta/FaceDepthInput so the shader is included in builds.")]
    public Shader depthShader;

    private static readonly int DepthId = Shader.PropertyToID("_FaceScreenDepth");
    private static readonly int AvailableId = Shader.PropertyToID("_FaceDepthAvailable");
    private static readonly int TexelSizeId = Shader.PropertyToID("_FaceScreenDepth_TexelSize");
    private static readonly int DepthVPId = Shader.PropertyToID("_FaceDepthVP");

    private Mesh hairDepthMesh;
    private MaterialPropertyBlock propertyBlock;
    private SkinnedMeshRenderer boundRenderer;
    private Texture previousDepth;
    private float previousAvailable;
    private Vector4 previousTexelSize;
    private Matrix4x4 previousVP;
    private Matrix4x4 depthVP;
    private RenderTexture screenDepth;
    private Material ownedMaterial;
    private bool drawingDepth;

    private void OnEnable()
    {
        // Unity can restore private object references across a script reload, while
        // MaterialPropertyBlock is not serializable. Rebuild the binding as a pair.
        propertyBlock = new MaterialPropertyBlock();
        boundRenderer = null;
        drawingDepth = false;
        RenderPipelineManager.beginCameraRendering += BeginCameraRendering;
    }

    private void OnDisable()
    {
        RenderPipelineManager.beginCameraRendering -= BeginCameraRendering;
        RestoreRendererBinding();
        ReleaseResources();
    }

    private void OnDestroy()
    {
        RenderPipelineManager.beginCameraRendering -= BeginCameraRendering;
        RestoreRendererBinding();
        ReleaseResources();
    }

    private void BeginCameraRendering(ScriptableRenderContext context, Camera camera)
    {
        if (!isActiveAndEnabled || drawingDepth || camera == null ||
            (camera.cameraType != CameraType.Game && camera.cameraType != CameraType.SceneView))
            return;

        RefreshRendererBinding();
        if (boundRenderer == null || hairRenderer == null || hairRenderer.sharedMesh == null)
        {
            PublishDepth(null, 0f);
            ReleaseResources();
            return;
        }

        Material material = GetDepthMaterial();
        int width = Mathf.Max(1, (camera.pixelWidth + 1) / 2);
        int height = Mathf.Max(1, (camera.pixelHeight + 1) / 2);
        if (material == null || !EnsureTexture(width, height))
        {
            PublishDepth(null, 0f);
            return;
        }

        drawingDepth = true;
        CommandBuffer commands = CommandBufferPool.Get("Herta face screen depth");
        try
        {
            float farDepth = SystemInfo.usesReversedZBuffer ? 0f : 1f;
            commands.SetRenderTarget(screenDepth);
            commands.SetViewport(new Rect(0f, 0f, width, height));
            // Unity converts the logical clear depth to the device's reversed-Z convention.
            // The color attachment stores device depth directly and uses farDepth instead.
            commands.ClearRenderTarget(true, true, new Color(farDepth, 0f, 0f, 1f), 1f);
            Matrix4x4 gpuProjection = GL.GetGPUProjectionMatrix(camera.projectionMatrix, true);
            depthVP = gpuProjection * camera.worldToCameraMatrix;
            commands.SetViewProjectionMatrices(camera.worldToCameraMatrix, gpuProjection);
            commands.SetGlobalMatrix("_HertaFaceDepthDrawVP", depthVP);

            if (hairRenderer.enabled && !hairRenderer.forceRenderingOff &&
                hairRenderer.gameObject.activeInHierarchy)
            {
                // beginCameraRendering precedes URP's native skinning setup. Bake the
                // current pose explicitly so editor and game cameras use valid geometry.
                if (hairDepthMesh == null)
                {
                    hairDepthMesh = new Mesh
                    {
                        name = "Herta hair face occlusion pose",
                        hideFlags = HideFlags.HideAndDontSave
                    };
                }
                hairRenderer.BakeMesh(hairDepthMesh);
                commands.DrawMesh(hairDepthMesh, hairRenderer.localToWorldMatrix, material, 0, 0);
            }

            context.ExecuteCommandBuffer(commands);
            PublishDepth(screenDepth, 1f);
        }
        finally
        {
            CommandBufferPool.Release(commands);
            drawingDepth = false;
        }
    }

    private Material GetDepthMaterial()
    {
        if (depthMaterial != null)
        {
            DestroyOwnedMaterial();
            return depthMaterial;
        }

        if (ownedMaterial != null && ownedMaterial.shader != depthShader)
            DestroyOwnedMaterial();

        if (ownedMaterial == null && depthShader != null)
        {
            ownedMaterial = new Material(depthShader)
            {
                name = "Herta face depth (temporary)",
                hideFlags = HideFlags.HideAndDontSave
            };
        }
        return ownedMaterial;
    }

    private bool EnsureTexture(int width, int height)
    {
        // One cache serves cameras sequentially and retains no Camera references.
        if (screenDepth != null && screenDepth.width == width && screenDepth.height == height &&
            screenDepth.IsCreated())
            return true;

        ReleaseTexture();
        var descriptor = new RenderTextureDescriptor(width, height)
        {
            graphicsFormat = GraphicsFormat.R16_UNorm,
            depthStencilFormat = GraphicsFormat.D16_UNorm,
            msaaSamples = 1,
            volumeDepth = 1,
            sRGB = false,
            useMipMap = false,
            autoGenerateMips = false
        };
        screenDepth = new RenderTexture(descriptor)
        {
            name = "Herta face screen depth (half resolution)",
            hideFlags = HideFlags.HideAndDontSave,
            filterMode = FilterMode.Bilinear,
            wrapMode = TextureWrapMode.Clamp,
            anisoLevel = 0
        };
        if (screenDepth.Create())
            return true;

        ReleaseTexture();
        return false;
    }

    private void RefreshRendererBinding()
    {
        if (boundRenderer == faceRenderer)
            return;

        RestoreRendererBinding();
        boundRenderer = faceRenderer;
        if (boundRenderer == null)
            return;

        if (propertyBlock == null)
            propertyBlock = new MaterialPropertyBlock();
        propertyBlock.Clear();
        boundRenderer.GetPropertyBlock(propertyBlock, 0);
        previousDepth = propertyBlock.GetTexture(DepthId);
        previousAvailable = propertyBlock.GetFloat(AvailableId);
        previousTexelSize = propertyBlock.GetVector(TexelSizeId);
        previousVP = propertyBlock.GetMatrix(DepthVPId);
    }

    private void PublishDepth(Texture texture, float available)
    {
        if (boundRenderer == null)
            return;

        // Read again each time so unrelated per-material overrides remain intact.
        propertyBlock.Clear();
        boundRenderer.GetPropertyBlock(propertyBlock, 0);
        propertyBlock.SetTexture(DepthId, texture);
        propertyBlock.SetFloat(AvailableId, available);
        propertyBlock.SetMatrix(DepthVPId, depthVP);
        propertyBlock.SetVector(TexelSizeId, texture == null ? Vector4.zero :
            new Vector4(1f / texture.width, 1f / texture.height, texture.width, texture.height));
        boundRenderer.SetPropertyBlock(propertyBlock, 0);
    }

    private void RestoreRendererBinding()
    {
        if (boundRenderer != null)
        {
            propertyBlock.Clear();
            boundRenderer.GetPropertyBlock(propertyBlock, 0);
            // MaterialPropertyBlock rejects null textures during editor domain reload.
            // Availability restores whether this neutral binding is sampled.
            propertyBlock.SetTexture(DepthId, previousDepth != null ? previousDepth : Texture2D.blackTexture);
            propertyBlock.SetFloat(AvailableId, previousAvailable);
            propertyBlock.SetVector(TexelSizeId, previousTexelSize);
            propertyBlock.SetMatrix(DepthVPId, previousVP);
            boundRenderer.SetPropertyBlock(propertyBlock, 0);
        }
        boundRenderer = null;
        previousDepth = null;
    }

    private void ReleaseResources()
    {
        ReleaseTexture();
        DestroyOwnedMaterial();
        if (hairDepthMesh != null)
            DestroyOwnedObject(hairDepthMesh);
        hairDepthMesh = null;
    }

    private void ReleaseTexture()
    {
        if (screenDepth == null)
            return;
        screenDepth.Release();
        DestroyOwnedObject(screenDepth);
        screenDepth = null;
    }

    private void DestroyOwnedMaterial()
    {
        if (ownedMaterial == null)
            return;
        DestroyOwnedObject(ownedMaterial);
        ownedMaterial = null;
    }

    private static void DestroyOwnedObject(Object instance)
    {
        if (Application.isPlaying)
            Destroy(instance);
        else
            DestroyImmediate(instance);
    }
}
