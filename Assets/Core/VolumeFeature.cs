using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class VolumeFeature : ScriptableRendererFeature
{
    VolumeDepthPass _depthPass;
    VolumeColorPass _colorPass;
    private RenderTargetHandle _depthTexture;
    private RenderTargetHandle _colorTexture;

    [Reload("Runtime/Data/PostProcessData.asset")]
    public PostProcessData postProcessData = null;
    public Shader blitAdd = null;
    public Material _blitMat = null;

    /// <inheritdoc/>
    public override void Create()
    {
#if UNITY_EDITOR
        ResourceReloader.ReloadAllNullIn(this, UniversalRenderPipelineAsset.packagePath);
        if (blitAdd == null)
            blitAdd = Shader.Find("Hidden/LowKick/BlitAdd");
        _blitMat = CoreUtils.CreateEngineMaterial(blitAdd);
#endif

        _depthPass = new VolumeDepthPass(
            RenderPassEvent.AfterRenderingPrePasses,
            RenderQueueRange.transparent,
            ~0
        );
        _colorPass = new VolumeColorPass(
            RenderPassEvent.AfterRenderingTransparents,
            RenderQueueRange.transparent,
            ~0
        );

        _depthTexture.Init("_VolumeDepthTexture");
        _colorTexture.Init("_VolumeColorTexture");
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        _depthPass.Setup(renderingData.cameraData.cameraTargetDescriptor, _depthTexture, postProcessData);
        _colorPass.Setup(renderingData.cameraData.cameraTargetDescriptor, _colorTexture, _blitMat);
        renderer.EnqueuePass(_depthPass);
        renderer.EnqueuePass(_colorPass);
    }
    
    public static Texture2D ConfigureDithering(PostProcessData data, ref int index)
    {
        var blueNoise = data.textures.blueNoise16LTex;

        if (blueNoise == null || blueNoise.Length == 0)
            return null; // Safe guard

        if (++index >= blueNoise.Length)
            index = 0;

        // Ideally we would be sending a texture array once and an index to the slice to use
        // on every frame but these aren't supported on all Universal targets
        return blueNoise[index];
    }
}