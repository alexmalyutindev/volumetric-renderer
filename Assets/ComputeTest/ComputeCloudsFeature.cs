using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Serialization;

public class ComputeCloudsFeature : ScriptableRendererFeature
{
    class CustomRenderPass : ScriptableRenderPass
    {
        private struct Params
        {
            public int Kernel;
            public Vector4 TraceScreenSize;
            public Vector4 FinalScreenSize;
            public Matrix4x4 InvViewProjection { get; set; }
        }

        private class ShaderIDs
        {
            // Input
            public static readonly int VolumeTexture = Shader.PropertyToID($"_{nameof(VolumeTexture)}");

            // Output
            public static readonly int CloudsLightingTextureRW =
                Shader.PropertyToID($"_{nameof(CloudsLightingTextureRW)}");

            public static readonly int CloudsPixelCoordToViewDirWS =
                Shader.PropertyToID($"_{nameof(CloudsPixelCoordToViewDirWS)}");

            public static readonly int TraceScreenSize = Shader.PropertyToID($"_{nameof(TraceScreenSize)}");
            public static readonly int FinalScreenSize = Shader.PropertyToID($"_{nameof(FinalScreenSize)}");
        }

        private readonly ComputeShader _shader;

        private Texture _volume;
        private RenderTargetIdentifier _volumeIdentifier;
        private readonly Material _blitMat;
        private Params _params;

        public CustomRenderPass(ComputeShader shader, Texture volume, Material blitMat)
        {
            _volume = volume;
            _volumeIdentifier = new RenderTargetIdentifier(_volume);
            _blitMat = blitMat;
            _shader = shader;
            _params = new Params()
            {
                Kernel = _shader.FindKernel("RenderClouds")
            };
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            _params.TraceScreenSize.x = desc.width >> 1;
            _params.TraceScreenSize.y = desc.height >> 1;
            _params.TraceScreenSize.z = 1f / _params.TraceScreenSize.x;
            _params.TraceScreenSize.w = 1f / _params.TraceScreenSize.y;

            _params.FinalScreenSize.x = desc.width;
            _params.FinalScreenSize.y = desc.height;

            var cloudsTargetDesc = new RenderTextureDescriptor()
            {
                colorFormat = RenderTextureFormat.ARGB32,
                width = (int) _params.TraceScreenSize.x,
                height = (int) _params.TraceScreenSize.y,
                autoGenerateMips = false,
                bindMS = false,
                enableRandomWrite = true,
                dimension = TextureDimension.Tex2D,
                msaaSamples = 1
            };
            cmd.GetTemporaryRT(ShaderIDs.CloudsLightingTextureRW, cloudsTargetDesc);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (renderingData.cameraData.isPreviewCamera)
                return;

            // Compute the number of tiles to evaluate
            int traceTx = ((int) _params.TraceScreenSize.x + (8 - 1)) / 8;
            int traceTy = ((int) _params.TraceScreenSize.y + (8 - 1)) / 8;

            var cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, profilingSampler))
            {
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                // Init params
                InitParams(renderingData, ref _params);

                cmd.SetComputeMatrixParam(_shader, ShaderIDs.CloudsPixelCoordToViewDirWS, _params.InvViewProjection);
                cmd.SetComputeTextureParam(_shader, _params.Kernel, ShaderIDs.VolumeTexture, _volumeIdentifier);
                cmd.SetComputeTextureParam(
                    _shader,
                    _params.Kernel,
                    ShaderIDs.CloudsLightingTextureRW,
                    ShaderIDs.CloudsLightingTextureRW
                );

                cmd.SetComputeVectorParam(_shader, ShaderIDs.TraceScreenSize, _params.TraceScreenSize);
                cmd.SetComputeVectorParam(_shader, ShaderIDs.FinalScreenSize, _params.FinalScreenSize);

                cmd.DispatchCompute(_shader, _params.Kernel, traceTx, traceTy, 1);
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                cmd.Blit(
                    new RenderTargetIdentifier(ShaderIDs.CloudsLightingTextureRW),
                    renderingData.cameraData.renderer.cameraColorTarget,
                    _blitMat
                );
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        private void InitParams(RenderingData renderingData, ref Params cloudParams)
        {
            var camera = renderingData.cameraData.camera;

            // Build a non-oblique projection matrix
            var projectionMatrixNonOblique = Matrix4x4.Perspective(
                camera.fieldOfView,
                camera.aspect,
                camera.nearClipPlane,
                camera.farClipPlane
            );
            // Convert the projection matrix to its  GPU version
            var gpuProjNonOblique = GL.GetGPUProjectionMatrix(projectionMatrixNonOblique, true);

            // Fetch the view and previous view matrix
            Matrix4x4 gpuView = camera.cameraToWorldMatrix; // hdCamera.mainViewConstants.viewMatrix;
            // Matrix4x4 prevGpuView = hdCamera.mainViewConstants.prevViewMatrix;

            // Build the non oblique view projection matrix
            var vpNonOblique = gpuProjNonOblique * gpuView;
            // var prevVpNonOblique = gpuProjNonOblique * prevGpuView;

            var invViewProjection = renderingData.cameraData.GetProjectionMatrix().inverse;
            cloudParams.InvViewProjection = camera.cameraToWorldMatrix * invViewProjection;
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            cmd.ReleaseTemporaryRT(ShaderIDs.CloudsLightingTextureRW);
        }
    }

    public ComputeShader cloudsShader;
    public Texture cloudsVolume;
    CustomRenderPass m_ScriptablePass;

    [SerializeField] [HideInInspector] private Shader _blitAdd = null;
    [SerializeField] [HideInInspector] private Material _blitMat = null;


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
        cloudsVolume ??= Resources.Load<Texture>("VolumeCloud");
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