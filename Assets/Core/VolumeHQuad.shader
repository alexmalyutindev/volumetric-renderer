Shader "VolumeHQuad"
{
    Properties
    {
        _BaseColor ("Color", Color) = (1.0, 1.0, 1.0, 1.0)
        _BaseMap ("Texture", 2D) = "white" {}
        [Toggle] _Jitter ("Jitter", Float) = 1.0

        _Density ("Density", Range(0, 10)) = 0.5
        [IntRange] _MaxStepsCount ("Max Ray Steps", Range(5, 50)) = 20
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
            ZTest Always
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma exclude_renderers gles gles3 glcore
            #pragma target 4.5

            #pragma vertex vert2
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
                float3 rayDir : TEXCOORD6;
                float3 rayOrigin : TEXCOORD7;

                float4 positionCS : SV_POSITION;

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
                output.positionCS = vertexInput.positionCS;

                output.positionOS = input.positionOS;
                output.positionVS = vertexInput.positionVS;
                output.positionWS = vertexInput.positionWS;
                output.viewDirWS = GetWorldSpaceViewDir(vertexInput.positionWS);
                output.fogCoord = ComputeFogFactor(vertexInput.positionCS.z);
                output.grabUV = ComputeScreenPos(vertexInput.positionCS);

                return output;
            }

            Varyings vert2(Attributes input)
            {
                Varyings output = (Varyings)0;

                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                // check if the current projection is orthographic or not from the current projection matrix
                bool isOrtho = unity_OrthoParams.w; // UNITY_MATRIX_P._m33 == 1.0;

                // viewer position, equivalent to _WorldSpaceCAmeraPos.xyz, but for the current view
                float3 worldSpaceViewerPos = UNITY_MATRIX_I_V._m03_m13_m23;

                // view forward
                float3 worldSpaceViewForward = -UNITY_MATRIX_I_V._m02_m12_m22;

                float4x4 o2w = GetObjectToWorldMatrix();
                // pivot position
                float3 worldSpacePivotPos = o2w._m03_m13_m23; // unity_ObjectToWorld._m03_m13_m23;

                // offset between pivot and camera
                float3 worldSpacePivotToView = worldSpaceViewerPos - worldSpacePivotPos;

                // get the max object scale
                float3 scale = float3(
                    length(unity_ObjectToWorld._m00_m10_m20),
                    length(unity_ObjectToWorld._m01_m11_m21),
                    length(unity_ObjectToWorld._m02_m12_m22)
                );
                float maxScale = max(abs(scale.x), max(abs(scale.y), abs(scale.z)));

                // calculate a camera facing rotation matrix
                float3 up = UNITY_MATRIX_I_V._m01_m11_m21;
                float3 forward = isOrtho ? -worldSpaceViewForward : normalize(worldSpacePivotToView);
                float3 right = normalize(cross(forward, up));
                up = cross(right, forward);
                float3x3 quadOrientationMatrix = float3x3(right, up, forward);

                // use the max scale to figure out how big the quad needs to be to cover the entire sphere
                // we're using a hardcoded object space radius of 0.5 in the fragment shader
                float maxRadius = maxScale * 0.5;

                // find the radius of a cone that contains the sphere with the point at the camera and the base at the pivot of the sphere
                // this means the quad is always scaled to perfectly cover only the area the sphere is visible within
                float quadScale = maxScale;
                if (!isOrtho)
                {
                    // get the sine of the right triangle with the hyp of the sphere pivot distance and the opp of the sphere radius
                    float sinAngle = maxRadius / length(worldSpacePivotToView);
                    // convert to cosine
                    float cosAngle = sqrt(1.0 - sinAngle * sinAngle);
                    // convert to tangent
                    float tanAngle = sinAngle / cosAngle;

                    // basically this, but should be faster
                    //tanAngle = tan(asin(sinAngle));

                    // get the opp of the right triangle with the 90 degree at the sphere pivot * 2
                    quadScale = tanAngle * length(worldSpacePivotToView) * 2.0;
                }

                // flatten mesh, in case it's a cube or sloped quad mesh
                input.positionOS.z = 0.0;

                // calculate world space position for the camera facing quad
                float3 worldPos = mul(input.positionOS.xyz * quadScale, quadOrientationMatrix) + worldSpacePivotPos;

                // calculate world space view ray direction and origin for perspective or orthographic
                float3 worldSpaceRayOrigin = worldSpaceViewerPos;
                float3 worldSpaceRayDir = worldPos - worldSpaceRayOrigin;
                if (isOrtho)
                {
                    worldSpaceRayDir = worldSpaceViewForward * -dot(worldSpacePivotToView, worldSpaceViewForward);
                    worldSpaceRayOrigin = worldPos - worldSpaceRayDir;
                }

                // output object space ray direction and origin
                output.rayDir = mul(unity_WorldToObject, float4(worldSpaceRayDir, 0.0));
                output.rayOrigin = mul(unity_WorldToObject, float4(worldSpaceRayOrigin, 1.0));

                // offset towards the camera for use with conservative depth
                #if defined(USE_CONSERVATIVE_DEPTH)
                worldPos += worldSpaceRayDir / dot(normalize(worldSpacePivotToView), worldSpaceRayDir) * maxRadius;
                #endif

                output.positionCS = TransformWorldToHClip(worldPos);
                output.grabUV = ComputeScreenPos(output.positionCS);

                return output;
            }

            #define SAMPLE_VOLUME(uvw) \
                saturate((SAMPLE_TEXTURE2D_LOD(_BaseMap, sampler_BaseMap, (uvw).xy + 0.5, 0).r - abs((uvw).z * 2)) * 10)
            // (SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uvw.xy + 0.5).r > abs(uvw.z * 2))

            #define SAMPLE_NOISE(screenUV) \
                (SAMPLE_TEXTURE2D( \
                    _BlueNoise, \
                    sampler_BlueNoise, \
                    screenUV * _BlueNoise_TexelSize.xy * _ScreenParams.xy * 0.5 \
                ).a)

            #define SHADER_STAGE_RAY_TRACING

            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                float frustumCorrection = 1 / -normalize(input.positionVS).z;

                float2 screenUV = input.grabUV.xy / input.grabUV.w;

                float sceneDepth = SampleSceneDepth(screenUV);


                int steps = _MaxStepsCount;
                float stepSize = 1.0 / steps;

                // Raymarching
                half currentDensity = 0.0;
                float transmittance = 1.0;

                float blueNoise = SAMPLE_NOISE(screenUV) - 0.5;

                float3 rayDir = normalize(input.rayDir);
                float3 rayOrigin = input.rayOrigin + rayDir * (length(input.rayDir) - 0.5 + blueNoise * stepSize * _Jitter);
                rayDir *= stepSize;


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
        
        // ------------------------------------------------------------------
        //  Scene view outline pass.
        Pass
        {
            Name "SceneSelectionPass"
            Tags { "LightMode" = "SceneSelectionPass" }

            BlendOp Add
            Blend One Zero
            ZWrite On
            Cull Off

            HLSLPROGRAM
            #define PARTICLES_EDITOR_META_PASS
            #pragma target 2.0

            // -------------------------------------
            // Particle Keywords
            #pragma shader_feature_local_fragment _ALPHATEST_ON
            #pragma shader_feature_local _FLIPBOOKBLENDING_ON

            // -------------------------------------
            // Unity defined keywords
            #pragma multi_compile_instancing
            #pragma instancing_options procedural:ParticleInstancingSetup

            #pragma vertex vert2
            #pragma fragment frag

            // #include "Packages/com.unity.render-pipelines.universal/Shaders/Particles/ParticlesEditorPass.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            float _ObjectId;
            float _PassValue;
            float4 _SelectionID;

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;

                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };
            
            Varyings vert2(Attributes input)
            {
                Varyings output = (Varyings)0;

                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                // check if the current projection is orthographic or not from the current projection matrix
                bool isOrtho = unity_OrthoParams.w; // UNITY_MATRIX_P._m33 == 1.0;

                // viewer position, equivalent to _WorldSpaceCAmeraPos.xyz, but for the current view
                float3 worldSpaceViewerPos = UNITY_MATRIX_I_V._m03_m13_m23;

                // view forward
                float3 worldSpaceViewForward = -UNITY_MATRIX_I_V._m02_m12_m22;

                float4x4 o2w = GetObjectToWorldMatrix();
                // pivot position
                float3 worldSpacePivotPos = o2w._m03_m13_m23; // unity_ObjectToWorld._m03_m13_m23;

                // offset between pivot and camera
                float3 worldSpacePivotToView = worldSpaceViewerPos - worldSpacePivotPos;

                // get the max object scale
                float3 scale = float3(
                    length(unity_ObjectToWorld._m00_m10_m20),
                    length(unity_ObjectToWorld._m01_m11_m21),
                    length(unity_ObjectToWorld._m02_m12_m22)
                );
                float maxScale = max(abs(scale.x), max(abs(scale.y), abs(scale.z)));

                // calculate a camera facing rotation matrix
                float3 up = UNITY_MATRIX_I_V._m01_m11_m21;
                float3 forward = isOrtho ? -worldSpaceViewForward : normalize(worldSpacePivotToView);
                float3 right = normalize(cross(forward, up));
                up = cross(right, forward);
                float3x3 quadOrientationMatrix = float3x3(right, up, forward);

                // use the max scale to figure out how big the quad needs to be to cover the entire sphere
                // we're using a hardcoded object space radius of 0.5 in the fragment shader
                float maxRadius = maxScale * 0.5;

                // find the radius of a cone that contains the sphere with the point at the camera and the base at the pivot of the sphere
                // this means the quad is always scaled to perfectly cover only the area the sphere is visible within
                float quadScale = maxScale;
                if (!isOrtho)
                {
                    // get the sine of the right triangle with the hyp of the sphere pivot distance and the opp of the sphere radius
                    float sinAngle = maxRadius / length(worldSpacePivotToView);
                    // convert to cosine
                    float cosAngle = sqrt(1.0 - sinAngle * sinAngle);
                    // convert to tangent
                    float tanAngle = sinAngle / cosAngle;

                    // basically this, but should be faster
                    //tanAngle = tan(asin(sinAngle));

                    // get the opp of the right triangle with the 90 degree at the sphere pivot * 2
                    quadScale = tanAngle * length(worldSpacePivotToView) * 2.0;
                }

                // flatten mesh, in case it's a cube or sloped quad mesh
                input.positionOS.z = 0.0;

                // calculate world space position for the camera facing quad
                float3 worldPos = mul(input.positionOS.xyz * quadScale, quadOrientationMatrix) + worldSpacePivotPos;

                // offset towards the camera for use with conservative depth
                #if defined(USE_CONSERVATIVE_DEPTH)
                worldPos += worldSpaceRayDir / dot(normalize(worldSpacePivotToView), worldSpaceRayDir) * maxRadius;
                #endif

                output.positionCS = TransformWorldToHClip(worldPos);

                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                return float4(_ObjectId, _PassValue, 1, 1);
            }
            
            ENDHLSL
        }
    }
}