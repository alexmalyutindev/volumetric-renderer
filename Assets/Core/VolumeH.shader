Shader "VolumeH"
{
    Properties
    {
        _BaseColor ("Color", Color) = (1.0, 1.0, 1.0, 1.0)
        _BaseMap ("Texture", 2D) = "white" {}
        _Cutoff("Alpha Clipping", Range(0.0, 1.0)) = 0.5
        [Toggle] _Jitter ("Jitter", Float) = 1.0

        _Density ("Density", Range(0, 10)) = 0.5
        [IntRange] _MaxStepsCount ("Max Ray Steps", Range(5, 50)) = 20
        [Toggle(_ALPHATEST_ON)] _AlphaClip ("Alpha Test", Float) = 0.0
        [Space]
        [Toggle(_VOLUME_SHADOWS)] _Shadows ("Shadows", Float) = 0.0
        _ShadowDensity ("ShadowDensity", Range(0, 20)) = 0.5
        [IntRange] _ShadowSteps ("Shadow Steps", Range(1, 50)) = 10
        _ShadowThreshold ("ShadowThreshold", Range(0, 1)) = 0.01
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
//            Blend SrcAlpha One
//            BlendOp Max
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
            #pragma instancing_options procedural:ParticleInstancingSetup

            #pragma shader_feature_local_fragment _VOLUME_SHADOWS

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/ParticlesInstancing.hlsl"

            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            half4 _BaseColor;
            float _Jitter;
            float _Density;
            float _ShadowDensity;
            float _ShadowThreshold;
            int _MaxStepsCount;
            int _ShadowSteps;
            CBUFFER_END

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            float4 _BaseMap_TexelSize;
            float4 _BaseMap_MipInfo;
            
            TEXTURE2D(_VolumeDepthTexture);
            SAMPLER(sampler_VolumeDepthTexture);

            TEXTURE2D(_BlueNoise);
            SAMPLER(sampler_BlueNoise);
            float4 _BlueNoise_TexelSize;

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float3 viewDirWS : TEXCOORD0;
                float4 grabUV : TEXCOORD1;
                float3 positionWS : TEXCOORD2;
                float3 positionVS : TEXCOORD3;
                float fogCoord : TEXCOORD4;
                float3 positionOS : TEXCOORD5;
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

                output.positionOS = input.positionOS;
                output.positionVS = vertexInput.positionVS;
                output.positionWS = vertexInput.positionWS;
                output.viewDirWS = GetWorldSpaceViewDir(vertexInput.positionWS);
                output.fogCoord = ComputeFogFactor(vertexInput.positionCS.z);
                output.grabUV = ComputeScreenPos(vertexInput.positionCS);

                return output;
            }

            #define SAMPLE_VOLUME(uvw) \
                saturate((SAMPLE_TEXTURE2D_LOD(_BaseMap, sampler_BaseMap, uvw.xy + 0.5, 0).r - abs(uvw.z * 2)) * 100)
                // (SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uvw.xy + 0.5).r > abs(uvw.z * 2))

            #define SAMPLE_NOISE(screenUV) \
                (SAMPLE_TEXTURE2D( \
                    _BlueNoise, \
                    sampler_BlueNoise, \
                    screenUV * _BlueNoise_TexelSize.xy * _ScreenParams.xy * 0.5 \
                ).a) \
            
            #define SHADER_STAGE_RAY_TRACING

            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                float frustumCorrection = 1 / -normalize(input.positionVS).z;

                float2 screenUV = input.grabUV.xy / input.grabUV.w;

                float volumeFront = SAMPLE_TEXTURE2D(_VolumeDepthTexture, sampler_VolumeDepthTexture, screenUV).r;
                volumeFront = volumeFront == 0 ? _ProjectionParams.z : volumeFront;
                volumeFront = LinearEyeDepth(volumeFront, _ZBufferParams);

                float volumeBack = LinearEyeDepth(input.vertex.z, _ZBufferParams);

                float sceneDepth = SampleSceneDepth(screenUV);
                sceneDepth = LinearEyeDepth(sceneDepth, _ZBufferParams);
                // Scene depth correction
                volumeBack = min(sceneDepth, volumeBack);

                float traceDist = max(0, volumeBack - volumeFront) * frustumCorrection;
                // traceDist = length(TransformWorldToObjectDir(traceDist * normalize(input.viewDirWS)));

                int steps = _MaxStepsCount * traceDist; // min(_MaxStepsCount, 1 / stepSize);
                float stepSize = traceDist / steps;

                // Raymarching
                half currentDensity = 0.0;
                float transmittance = 1.0;

                float3 rayDir = input.viewDirWS / input.positionVS.z;
                float3 rayOrigin = _WorldSpaceCameraPos + rayDir * volumeFront * frustumCorrection;
                rayOrigin = TransformWorldToObject(rayOrigin);

                float blueNoise = SAMPLE_NOISE(screenUV) - 0.5;

                rayDir = TransformWorldToObjectDir(rayDir, false) * stepSize;
                rayOrigin += rayDir * blueNoise * _Jitter;

                float shadowStepSize = 0.5 / _ShadowSteps;
                float shadowDensity = _ShadowDensity * shadowStepSize;
                float shadowthresh = -log(_ShadowThreshold) / shadowDensity;
                
                float3 lightDir = TransformWorldToObjectDir(_MainLightPosition.xyz);
                lightDir *= shadowStepSize;

                float stepDensity = _Density * stepSize;
                float lightEnergy = 0.0;

                UNITY_LOOP
                for (int i = 0; i < steps; i++)
                {
                    float sample = SAMPLE_VOLUME(rayOrigin);

                    //Sample Light Absorption and Scattering
                    if (sample > 0.001)
                    {
                        blueNoise = SAMPLE_NOISE(rayOrigin.xy) - 0.5;
                        float3 lightRay = rayOrigin + lightDir * blueNoise * _Jitter;
                        half shadowDist = 0;

                        UNITY_LOOP
                        for (int s = 0; s < _ShadowSteps; s++)
                        {
                            lightRay += lightDir;
                            half lightSample = SAMPLE_VOLUME(lightRay);

                            half3 shadowBoxTest = floor(abs(lightRay) + 0.5);
                            half exitShadowBox = shadowBoxTest.x + shadowBoxTest.y + shadowBoxTest.z;

                            
                            shadowDist += lightSample;
                            if (shadowDist > shadowthresh || exitShadowBox >= 1.0)
                            {
                                break;
                            }
                        }

                        currentDensity = saturate(sample * stepDensity);
                        half shadowTerm = exp(-shadowDist * shadowDensity);
                        half absorbedLight = shadowTerm * currentDensity;
                        lightEnergy += absorbedLight * transmittance;
                        transmittance *= 1.0 - currentDensity;
                    }

                    if (transmittance < 0.01)
                    {
                        transmittance = 0;
                        break;
                    }

                    rayOrigin += rayDir;
                }

                half3 color = lerp(_BaseColor.rgb, _MainLightColor.rgb, saturate(lightEnergy));
                return half4(color, 1 - transmittance);
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
            #pragma instancing_options procedural:ParticleInstancingSetup

            #include "Packages/com.unity.render-pipelines.universal/Shaders/UnlitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthOnlyPass.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/ParticlesInstancing.hlsl"

            Varyings DepthOnlyVertex0(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                output.uv = TRANSFORM_TEX(input.texcoord, _BaseMap);
                output.positionCS = TransformObjectToHClip(input.position.xyz);
                output.positionCS.z = output.positionCS.z < _ProjectionParams.y ? 0 : output.positionCS.z;
                return output;
            }
            ENDHLSL
        }
    }
}