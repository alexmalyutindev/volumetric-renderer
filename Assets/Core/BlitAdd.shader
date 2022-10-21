Shader "Hidden/LowKick/BlitAdd"
{
    Properties
    {
        _MainTex("Main", 2D) = "white" {}
    }
    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline"
        }
        LOD 100

        Pass
        {
            Name "BlitAdd"
            ZTest Always
            ZWrite Off
            Cull Off
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex FullscreenVert
            #pragma fragment Fragment
            #pragma multi_compile_fragment _ _LINEAR_TO_SRGB_CONVERSION
            #pragma multi_compile _ _USE_DRAW_PROCEDURAL

            #include "Packages/com.unity.render-pipelines.universal/Shaders/Utils/Fullscreen.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"

            TEXTURE2D_X(_MainTex);
            SAMPLER(sampler_MainTex);
            float4 _MainTex_TexelSize;

            // Bicubic Filtering in Fewer Taps: https://vec3.ca/bicubic-filtering-in-fewer-taps/
            half4 BicubicCatmullRom(Texture2D tex, sampler samplerTex, float2 iTc, float4 texelSize)
            {
                iTc *= texelSize.zw;

                //round tc *down* to the nearest *texel center*
                float2 tc = floor(iTc - 0.5) + 0.5;

                //compute the fractional offset from that texel center
                //to the actual coordinate we want to filter at

                float2 f = iTc - tc;

                //we'll need the second and third powers
                //of f to compute our filter weights

                float2 f2 = f * f;
                float2 f3 = f2 * f;

                //compute the filter weights

                float2 w0 = f2 - 0.5 * (f3 + f);
                float2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
                float2 w3 = 0.5 * (f3 - f2);
                float2 w2 = 1.0 - w0 - w1 - w3;

                //get our texture coordinates

                float2 s0 = w0 + w1;
                float2 s1 = w2 + w3;

                float2 f0 = w1 / (w0 + w1);
                float2 f1 = w3 / (w2 + w3);

                float2 t0 = tc - 1 + f0;
                float2 t1 = tc + 1 + f1;

                //and sample and blend

                return
                    SAMPLE_TEXTURE2D(tex, samplerTex, float2( t0.x, t0.y ) * texelSize.xy) * s0.x * s0.y
                    + SAMPLE_TEXTURE2D(tex, samplerTex, float2( t1.x, t0.y ) * texelSize.xy) * s1.x * s0.y
                    + SAMPLE_TEXTURE2D(tex, samplerTex, float2( t0.x, t1.y ) * texelSize.xy) * s0.x * s1.y
                    + SAMPLE_TEXTURE2D(tex, samplerTex, float2( t1.x, t1.y ) * texelSize.xy) * s1.x * s1.y;
            }

            // Standard box filtering
            half4 UpsampleBox(Texture2D tex, sampler samplerTex, float2 uv, float2 texelSize, float4 sampleScale)
            {
                float4 d = texelSize.xyxy * float4(-1.0, -1.0, 1.0, 1.0) * (sampleScale * 0.5);

                half4 s;
                s = (SAMPLE_TEXTURE2D(tex, samplerTex, UnityStereoTransformScreenSpaceTex(uv + d.xy)));
                s += (SAMPLE_TEXTURE2D(tex, samplerTex, UnityStereoTransformScreenSpaceTex(uv + d.zy)));
                s += (SAMPLE_TEXTURE2D(tex, samplerTex, UnityStereoTransformScreenSpaceTex(uv + d.xw)));
                s += (SAMPLE_TEXTURE2D(tex, samplerTex, UnityStereoTransformScreenSpaceTex(uv + d.zw)));

                return s * (1.0 / 4.0);
            }

            half4 Fragment(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                half4 col = UpsampleBox(_MainTex, sampler_MainTex, input.uv, _MainTex_TexelSize.xy, 2);

                #ifdef _LINEAR_TO_SRGB_CONVERSION
                col = LinearToSRGB(col);
                #endif

                return col;
            }
            ENDHLSL
        }
    }
}