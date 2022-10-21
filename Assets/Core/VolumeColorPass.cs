using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class VolumeColorPass : ScriptableRenderPass
{
    readonly int kDepthBufferBits = 32;

    private RenderTargetHandle colorAttachmentHandle { get; set; }
    internal RenderTextureDescriptor descriptor { get; private set; }

    FilteringSettings m_FilteringSettings;
    ShaderTagId m_ShaderTagId = new ShaderTagId("VolumeColor");
    private Material _blitMat;
    private RenderTargetIdentifier _renderTargetIdentifier;

    /// <summary>
    /// Create the DepthOnlyPass
    /// </summary>
    public VolumeColorPass(RenderPassEvent evt, RenderQueueRange renderQueueRange, LayerMask layerMask)
    {
        base.profilingSampler = new ProfilingSampler(nameof(VolumeColorPass));
        m_FilteringSettings = new FilteringSettings(renderQueueRange, layerMask);
        renderPassEvent = evt;
    }

    /// <summary>
    /// Configure the pass
    /// </summary>
    public void Setup(
        RenderTextureDescriptor baseDescriptor,
        RenderTargetHandle depthAttachmentHandle,
        Material blitMat
    )
    {
        _blitMat = blitMat;
        colorAttachmentHandle = depthAttachmentHandle;
        baseDescriptor.colorFormat = RenderTextureFormat.ARGB32;
        baseDescriptor.depthBufferBits = kDepthBufferBits;
        baseDescriptor.width >>= 1;
        baseDescriptor.height >>= 1;

        baseDescriptor.msaaSamples = 1;
        descriptor = baseDescriptor;
    }

    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        cmd.GetTemporaryRT(colorAttachmentHandle.id, descriptor, FilterMode.Bilinear);
        _renderTargetIdentifier = new RenderTargetIdentifier(colorAttachmentHandle.Identifier(), 0, CubemapFace.Unknown, -1);
        ConfigureTarget(_renderTargetIdentifier);
        ConfigureClear(ClearFlag.All, Color.clear);
    }

    // public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
    // {
    //     cmd.GetTemporaryRT(depthAttachmentHandle.id, descriptor, FilterMode.Point);
    //     ConfigureTarget(new RenderTargetIdentifier(depthAttachmentHandle.Identifier(), 0, CubemapFace.Unknown, -1));
    //     // ConfigureClear(ClearFlag.All, Color.black);
    // }

    /// <inheritdoc/>
    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        // NOTE: Do NOT mix ProfilingScope with named CommandBuffers i.e. CommandBufferPool.Get("name").
        // Currently there's an issue which results in mismatched markers.
        CommandBuffer cmd = CommandBufferPool.Get();
        using (new ProfilingScope(cmd, profilingSampler))
        {
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();

            var sortFlags = renderingData.cameraData.defaultOpaqueSortFlags;
            sortFlags = SortingCriteria.BackToFront;
            var drawSettings = CreateDrawingSettings(m_ShaderTagId, ref renderingData, sortFlags);
            drawSettings.perObjectData = PerObjectData.None;

            context.DrawRenderers(renderingData.cullResults, ref drawSettings, ref m_FilteringSettings);

            cmd.Blit(colorAttachmentHandle.Identifier(), renderingData.cameraData.renderer.cameraColorTarget, _blitMat);
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
        }

        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }

    /// <inheritdoc/>
    public override void OnCameraCleanup(CommandBuffer cmd)
    {
        if (cmd == null)
            throw new ArgumentNullException(nameof(cmd));

        if (colorAttachmentHandle != RenderTargetHandle.CameraTarget)
        {
            cmd.ReleaseTemporaryRT(colorAttachmentHandle.id);
            colorAttachmentHandle = RenderTargetHandle.CameraTarget;
        }
    }
}