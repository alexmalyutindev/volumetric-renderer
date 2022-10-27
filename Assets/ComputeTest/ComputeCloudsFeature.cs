using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Serialization;

public class ComputeCloudsFeature : ScriptableRendererFeature
{
    class CustomRenderPass : ScriptableRenderPass
    {
        private readonly ComputeShader _cloudsShader;
        private int _renderCloudsKernel;

        private Vector4 _TraceScreenSize;
        private readonly int _traceScreenSice_ID = Shader.PropertyToID("_TraceScreenSize");

        private RenderTargetHandle _CloudsLightingTextureRW;
        private readonly int _cloudsLightingTextureRW_ID = Shader.PropertyToID("_CloudsLightingTextureRW");

        private Texture _volume;
        private readonly Material _blitMat;

        public CustomRenderPass(ComputeShader cloudsShader, Texture volume, Material blitMat)
        {
            _volume = volume;
            _blitMat = blitMat;
            _cloudsShader = cloudsShader;
            _renderCloudsKernel = _cloudsShader.FindKernel("RenderClouds");
            _CloudsLightingTextureRW = new RenderTargetHandle("_CloudsLightingTextureRW");
            _TraceScreenSize = new Vector4(1920, 1080);
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            cmd.GetTemporaryRT(
                _CloudsLightingTextureRW.id,
                new RenderTextureDescriptor()
                {
                    colorFormat = RenderTextureFormat.Default,
                    width = (int) _TraceScreenSize.x,
                    height = (int) _TraceScreenSize.y,
                    autoGenerateMips = false,
                    bindMS = false,
                    depthBufferBits = 32,
                    enableRandomWrite = true,
                    dimension = TextureDimension.Tex2D,
                    msaaSamples = 1
                }
            );
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // Compute the number of tiles to evaluate
            int traceTX = ((int) _TraceScreenSize.x + (8 - 1)) / 8;
            int traceTY = ((int) _TraceScreenSize.y + (8 - 1)) / 8;

            var cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, profilingSampler))
            {
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                _cloudsShader.SetTexture(_renderCloudsKernel, Shader.PropertyToID("_VolumeTexture"), _volume);

                cmd.SetComputeTextureParam(
                    _cloudsShader,
                    _renderCloudsKernel,
                    _cloudsLightingTextureRW_ID,
                    _CloudsLightingTextureRW.id
                );
                var invViewProjection = renderingData.cameraData.GetProjectionMatrix().inverse;
                invViewProjection = renderingData.cameraData.GetViewMatrix().inverse * invViewProjection;
                // invViewProjection = renderingData.cameraData.camera.cameraToWorldMatrix * invViewProjection;
                cmd.SetComputeMatrixParam(
                    _cloudsShader,
                    Shader.PropertyToID("_CloudsPixelCoordToViewDirWS"),
                    invViewProjection
                );
                cmd.SetComputeVectorParam(_cloudsShader, _traceScreenSice_ID, _TraceScreenSize);
                cmd.DispatchCompute(_cloudsShader, _renderCloudsKernel, traceTX, traceTY, 1);
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                cmd.Blit(
                    new RenderTargetIdentifier(_CloudsLightingTextureRW.id), 
                    renderingData.cameraData.renderer.cameraColorTarget, 
                    _blitMat
                );
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            cmd.ReleaseTemporaryRT(_CloudsLightingTextureRW.id);
        }
    }

    public ComputeShader cloudsShader;
    public Texture cloudsVolume;
    CustomRenderPass m_ScriptablePass;

    [SerializeField] private Shader _blitAdd = null;
    [SerializeField] private Material _blitMat = null;


    /// <inheritdoc/>
    public override void Create()
    {
#if UNITY_EDITOR
        ResourceReloader.ReloadAllNullIn(this, UniversalRenderPipelineAsset.packagePath);
        if (_blitAdd == null)
            _blitAdd = Shader.Find("Hidden/LowKick/BlitAdd");
        _blitMat = CoreUtils.CreateEngineMaterial(_blitAdd);
#endif
        cloudsShader = Resources.Load<ComputeShader>("Clouds");
        cloudsVolume = Resources.Load<Texture>("VolumeCloud");
        m_ScriptablePass = new CustomRenderPass(cloudsShader, cloudsVolume, _blitMat);

        // Configures where the render pass should be injected.
        m_ScriptablePass.renderPassEvent = RenderPassEvent.AfterRenderingSkybox;
    }

    // Here you can inject one or multiple render passes in the renderer.
    // This method is called when setting up the renderer once per-camera.
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        renderer.EnqueuePass(m_ScriptablePass);
    }
}