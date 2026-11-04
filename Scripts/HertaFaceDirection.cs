using UnityEngine;

namespace HertaRdc
{
    [ExecuteAlways]
    [DisallowMultipleComponent]
    public sealed class HertaFaceDirection : MonoBehaviour
    {
        [SerializeField] private SkinnedMeshRenderer faceRenderer;
        [SerializeField] private Transform head;
        [SerializeField] private Transform characterRoot;
        private MaterialPropertyBlock block;

        private void OnEnable() { UpdateFace(); }
        private void LateUpdate() { UpdateFace(); }

        public void UpdateFace()
        {
            if (faceRenderer == null || head == null || characterRoot == null) return;
            if (block == null) block = new MaterialPropertyBlock();
            faceRenderer.GetPropertyBlock(block, 0);
            block.SetVector("_HeadAxisX", head.right.normalized);
            block.SetVector("_HeadAxisY", head.up.normalized);
            block.SetVector("_HeadAxisZ", head.forward.normalized);
            block.SetVector("_CharacterOrigin", characterRoot.position);
            // Captured main light is a world-space direction; rotating the character
            // must change its angle relative to the head, not rotate the light too.
            block.SetVector("_FaceLightDirection",
                new Vector3(-0.380356461f, 0.435889959f, 0.815676987f));
            faceRenderer.SetPropertyBlock(block, 0);
        }
    }
}
