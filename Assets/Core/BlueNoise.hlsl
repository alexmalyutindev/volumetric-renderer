#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"

TEXTURE2D(_BlueNoise);
SAMPLER(sampler_BlueNoise);
float4 _BlueNoise_TexelSize;

#define SAMPLE_BLUENOISE(screenUV, scale) \
    (SAMPLE_TEXTURE2D_LOD( \
    _BlueNoise, \
    sampler_BlueNoise, \
    screenUV * _BlueNoise_TexelSize.xy * _ScreenParams.xy * scale, \
    0).a)