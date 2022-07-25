Shader "Volume"
{
    Properties
    {
        _BaseColor ("Color", Color) = (1.0, 1.0, 1.0, 1.0)
        _BaseMap ("Texture", 2D) = "white" {}
        _Volume ("Volume", 3D) = "cube" {}
        _Density ("Density", Range(0, 2)) = 0.5
        _Cutoff("Alpha Clipping", Range(0.0, 1.0)) = 0.5
        [IntRange] _MaxStepsCount ("Max Ray Steps", Range(1, 50)) = 20
        [Toggle(_ALPHATEST_ON)] _AlphaClip ("Alpha Test", Float) = 0.0
        [Toggle(_VOLUME_SHADOWS)] _Shadows ("Shadows", Float) = 0.0

    }
    SubShader
    {
        Tags
        {
            "Queue" = "Transparent"
            "RenderType" = "Transparent"
            "RenderPipeline" = "UniversalPipeline"
            "LightMode" = "VolumeColor"
            "IgnoreProjector" = "True"
            "ShaderModel"="4.5"
        }
        LOD 300

        Pass
        {
            Name "Volume"

            Blend SrcAlpha OneMinusSrcAlpha
            ZTest Always
            ZWrite Off
            Cull Front

            HLSLPROGRAM
            #pragma exclude_renderers gles gles3 glcore
            #pragma target 4.5

            #pragma vertex vert
            #pragma fragment frag
            #pragma shader_feature_local_fragment _ALPHATEST_ON
            #pragma shader_feature_local_fragment _ALPHAPREMULTIPLY_ON

            // -------------------------------------
            // Unity defined keywords
            #pragma multi_compile_fog
            #pragma multi_compile_instancing
            #pragma multi_compile _ DOTS_INSTANCING_ON

            #pragma shader_feature_local_fragment _VOLUME_SHADOWS

            #include "Packages/com.unity.render-pipelines.universal/Shaders/UnlitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            float _Density;
            half _MaxStepsCount;
            TEXTURE3D(_Volume);
            SAMPLER(sampler_Volume);

            TEXTURE2D(_VolumeDepthTexture);
            SAMPLER(sampler_VolumeDepthTexture);
            
            TEXTURE2D(_BlueNoise);
            float4 _BlueNoise_TexelSize;
            SAMPLER(sampler_BlueNoise);

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float3 viewDirVS : TEXCOORD0;
                float fogCoord : TEXCOORD1;
                float4 grabUV : TEXCOORD2;
                float3 positionWS : TEXCOORD3;
                float4 vertex : SV_POSITION;

                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings vert(Attributes input)
            {
                Varyings output = (Varyings)0;

                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                output.vertex = vertexInput.positionCS;

                output.positionWS = input.positionOS.xyz + 0.5; // vertexInput.positionWS;
                output.viewDirVS = vertexInput.positionVS;
                output.fogCoord = ComputeFogFactor(vertexInput.positionCS.z);
                output.grabUV = ComputeScreenPos(vertexInput.positionCS);

                return output;
            }

            #define SAMPLE_VOLUME(uvw) SAMPLE_TEXTURE3D_LOD(_Volume, sampler_Volume, uvw, 0).r
            
            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                float frustumCorrection = 1 / -normalize(input.viewDirVS).z;

                float2 screenUV = input.grabUV.xy / input.grabUV.w;

                float blueNoise = SAMPLE_TEXTURE2D(_BlueNoise, sampler_BlueNoise, screenUV * _BlueNoise_TexelSize.xy * _ScreenParams.xy).a;
                
                float volumeFront = SAMPLE_TEXTURE2D(_VolumeDepthTexture, sampler_VolumeDepthTexture, screenUV).r;
                volumeFront = volumeFront == 0 ? _ProjectionParams.z : volumeFront;
                volumeFront = LinearEyeDepth(volumeFront, _ZBufferParams) * frustumCorrection;
                float volumeBack = LinearEyeDepth(input.vertex.z, _ZBufferParams) * frustumCorrection; // input.viewDirVS.z; //

                float sceneDepth = SampleSceneDepth(screenUV);
                sceneDepth = LinearEyeDepth(sceneDepth, _ZBufferParams) * frustumCorrection;

                float depthOffset = max(0, volumeBack - volumeFront);
                // Scene depth correction
                volumeBack = min(sceneDepth, volumeBack);
                // volumeFront = min(0, volumeFront);
                // return half4(volumeFront.xxx, 1);

                // return half4(normParam.xxx, 1);
                float traceDist = max(0, volumeBack - volumeFront);
                // return half4(traceDist.xxx, 1);

                float stepSize = 0.001;
                half steps = min(_MaxStepsCount, traceDist / stepSize);
                stepSize = traceDist / steps;
                // return half4(steps.xxx /  20, 1);

                half light = 0.0h;
                float3 lightDir = -_MainLightPosition.xyz * stepSize;
                
                half density = 0.0;
                float3 rayDir = -GetWorldSpaceViewDir(input.positionWS);
                rayDir = normalize(rayDir); // / frustumCorrection;
                float3 rayOrigin = input.positionWS - rayDir * (depthOffset);
                rayDir *= stepSize  * (1 - blueNoise * 0.3);

                float stepDensity = _Density * stepSize;
                for (half i = 0; i < steps; i++)
                {
                    // SAMPLE_TEXTURE3D_LOD(_Volume, sampler_Volume, rayOrigin, 0).r * _Density * stepSize;
                    density += SAMPLE_VOLUME(rayOrigin) * stepDensity;

                    #ifdef _VOLUME_SHADOWS
                    light = 0.0h;
                    float3 lightRay = rayOrigin;
                    
                    half shadowDensity = 0.0;
                    for (half j = 0; j < 10; j++)
                    {
                        lightRay += lightDir;
                        shadowDensity += SAMPLE_VOLUME(rayOrigin) * stepDensity;

                        // if (shadowDensity < 0.01)
                        //     break;
                    }
                    light += exp(-shadowDensity * 2);
                    #else
                    light = 1.0h;
                    #endif

                    if (density > 1)
                        break;

                    rayOrigin += rayDir;
                }

                light = saturate(light);
                return half4(_BaseColor.rgb * light * _MainLightColor.rgb, saturate(density));
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags
            {
                "LightMode" = "VolumeDepth"
            }

            ZWrite On
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma exclude_renderers gles gles3 glcore
            #pragma target 4.5

            #pragma vertex DepthOnlyVertex
            #pragma fragment DepthOnlyFragment

            // -------------------------------------
            // Material Keywords
            #pragma shader_feature_local_fragment _ALPHATEST_ON

            //--------------------------------------
            // GPU Instancing
            #pragma multi_compile_instancing
            #pragma multi_compile _ DOTS_INSTANCING_ON

            #include "Packages/com.unity.render-pipelines.universal/Shaders/UnlitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthOnlyPass.hlsl"
            ENDHLSL
        }
    }
}