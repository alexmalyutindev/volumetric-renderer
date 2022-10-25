Shader "VolumeH_Cube"
{
    Properties
    {
        _Cutoff("Alpha Clipping", Range(0.0, 1.0)) = 0.5
        _BaseColor ("Color", Color) = (1.0, 1.0, 1.0, 1.0)
        _BaseMap ("Texture", 2D) = "white" {}
        _Volume ("Volume", 3D) = "white" {}
        [Toggle(_VOLUME)] _VolumeKw ("Use Volume", Float) = 0.0

        [Toggle] _Jitter ("Jitter", Float) = 1.0

        _Hardness ("Hardness", Float) = 10
        _Density ("Density", Range(0, 10)) = 0.5
        [IntRange] _MaxStepsCount ("Max Ray Steps", Range(5, 50)) = 20

        [Header(Shadow)][Space]
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

//            Blend SrcAlpha One, SrcAlpha DstAlpha
//            BlendOp Add, Add
//            ZTest Off
//            Blend SrcAlpha OneMinusSrcAlpha, SrcAlpha DstAlpha
//            BlendOp Add, Max
            Blend SrcAlpha OneMinusSrcAlpha
            Cull Front

            HLSLPROGRAM
            #pragma exclude_renderers gles gles3 glcore
            #pragma target 4.5

            #pragma vertex Vertex
            #pragma fragment Fragment

            #pragma shader_feature_local_fragment _ALPHATEST_ON
            #pragma shader_feature_local_fragment _ALPHAPREMULTIPLY_ON

            #pragma shader_feature_local _VOLUME

            // -------------------------------------
            // Unity defined keywords
            #pragma multi_compile_fog
            #pragma multi_compile_instancing
            #pragma multi_compile _ DOTS_INSTANCING_ON
            // TODO: Particles instancing
            // #pragma instancing_options procedural:ParticleInstancingSetup

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            half4 _BaseColor;
            float _Cutoff;
            float _Hardness;
            float _Density;
            float _ShadowDensity;
            float _ShadowThreshold;
            int _MaxStepsCount;
            int _ShadowSteps;
            int _Jitter;
            CBUFFER_END

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            float4 _BaseMap_TexelSize;
            float4 _BaseMap_MipInfo;

            TEXTURE3D(_Volume);
            SAMPLER(sampler_Volume);

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
                float3 rayDir : TEXCOORD6;
                float3 rayOrigin : TEXCOORD7;

                float4 positionCS : SV_POSITION;

                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            #define SHADER_STAGE_RAY_TRACING

            Varyings Vertex(Attributes input)
            {
                Varyings output = (Varyings)0;

                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                float3 positionWS = TransformObjectToWorld(input.positionOS);
                output.positionCS = TransformWorldToHClip(positionWS);

                output.viewDirWS = GetWorldSpaceViewDir(positionWS);
                output.positionVS = TransformWorldToView(positionWS);
                output.rayDir = TransformWorldToObjectDir(-output.viewDirWS, false);
                output.rayOrigin = TransformWorldToObject(_WorldSpaceCameraPos);
                output.grabUV = ComputeScreenPos(output.positionCS);

                return output;
            }


            #ifdef _VOLUME
            #define SAMPLE_VOLUME(uvw) (SAMPLE_TEXTURE3D_LOD(_Volume, sampler_Volume, (uvw).xyz + 0.5, 0).r)
            #else
            #define SAMPLE_VOLUME(uvw) \
                saturate((SAMPLE_TEXTURE2D_LOD(_BaseMap, sampler_BaseMap, (uvw).xy + 0.5, 0).r - abs((uvw).z * 2)) * _Hardness)
            #endif

            #define SAMPLE_NOISE(screenUV) \
                (SAMPLE_TEXTURE2D_LOD( \
                    _BlueNoise, \
                    sampler_BlueNoise, \
                    screenUV * _BlueNoise_TexelSize.xy * _ScreenParams.xy * 0.5, \
                    0 \
                ).a)

            float2 BoxIntersection(in float3 ro, in float3 rd, in float3 rad, in float depth)
            {
                float3 m = 1.0 / rd;
                float3 n = m * ro;
                float3 k = abs(m) * rad;
                float3 t1 = -n - k;
                float3 t2 = -n + k;

                float tN = max(max(t1.x, t1.y), t1.z);
                float tF = min(min(t2.x, t2.y), t2.z);

                // not visible (behind camera or behind dbuffer)
                if (tF < 0.0 || tN > depth) return -1.0;

                // clip integration segment from camera to dbuffer
                tN = max(tN, 0.0);
                tF = min(tF, depth);

                return float2(tN, tF);
            }

            half4 Fragment(Varyings input, out float depth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                depth = -1; // input.positionCS.z;

                float frustumCorrection = 1 / -normalize(input.positionVS).z;

                float2 screenUV = input.grabUV.xy / input.grabUV.w;
                float sceneDepth = SampleSceneDepth(screenUV);
                sceneDepth = LinearEyeDepth(sceneDepth, _ZBufferParams);

                float fragmentEyeDepth = -input.positionVS.z;
                float3 worldPos = _WorldSpaceCameraPos - ((input.viewDirWS / fragmentEyeDepth) * sceneDepth);
                float3 depthOS = TransformWorldToObject(worldPos);
                sceneDepth = length(depthOS - input.rayOrigin);

                // Raymarching
                half currentDensity = 0.0;
                float transmittance = 1.0;

                float blueNoise = SAMPLE_NOISE(screenUV) - 0.5;

                // TODO: Normalize in vertex pass, and store lenght in w component
                float3 rayDir = normalize(input.rayDir);
                float2 boxIntersection = BoxIntersection(input.rayOrigin, rayDir, 0.5, sceneDepth);
                float traceDist = (boxIntersection.y - boxIntersection.x);
                int steps = _MaxStepsCount;
                float stepSize = traceDist / steps;

                float3 rayOrigin = input.rayOrigin + rayDir * (boxIntersection.x + blueNoise * stepSize * _Jitter);
                rayDir *= stepSize;

                float shadowStepSize = 0.5 / _ShadowSteps;
                float shadowDensity = _ShadowDensity * shadowStepSize;
                float shadowThresh = -log(_ShadowThreshold) / shadowDensity;

                float3 lightDir = TransformWorldToObjectDir(_MainLightPosition.xyz);
                lightDir *= shadowStepSize;

                float stepDensity = _Density * stepSize;
                float lightEnergy = 0.0;
                float sampleDist = boxIntersection.x;

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
                            if (shadowDist > shadowThresh || exitShadowBox >= 1.0)
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

                    if (transmittance < 0.2 && depth < 0)
                    {
                        float4 positionCS = TransformObjectToHClip(rayOrigin); //  + rayDir * blueNoise);
                        depth = positionCS.z / positionCS.w;
                    }

                    if (transmittance < 0.01)
                        break;

                    rayOrigin += rayDir;
                    sampleDist += stepSize;
                }

                float alpha = 1 - transmittance;
                clip(alpha - _Cutoff);

                // return half4(LinearEyeDepth(depth, _ZBufferParams).xxx, 1);
                // depth = input.positionCS.z;
                // if (alpha < _Cutoff)
                //     depth = 0;

                half3 color = lerp(_BaseColor.rgb, _MainLightColor.rgb, saturate(lightEnergy));
                return half4(color, alpha);
            }
            ENDHLSL
        }
    }
}