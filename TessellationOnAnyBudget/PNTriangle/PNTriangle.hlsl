//--------------------------------------------------------------------------------------
// File: PNTriangle.hlsl
//
// These shaders implement the PN-Triangles tessellation technique
//
// Contributed by the AMD Developer Relations Team
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//--------------------------------------------------------------------------------------

// #define QUADRATIC_NORMAL

//--------------------------------------------------------------------------------------
// Constant buffer
//--------------------------------------------------------------------------------------

cbuffer cbPNTriangles : register( b0 )
{
    float4x4    g_f4x4World;                // World matrix for object
    float4x4    g_f4x4View;                 // View matrix for object
	float4x4    g_f4x4WorldView;            // Wrold * View matrix
    float4x4    g_f4x4Projection;           // Projection matrix
    float4x4    g_f4x4ViewProjection;       // View * Projection matrix
    float4x4    g_f4x4WorldViewProjection;  // World * View * Projection matrix
    float4      g_f4LightDir;               // Light direction vector
    float4      g_f4Eye;                    // Eye
    float4      g_f4ViewVector;             // View Vector
    float4      g_f4TessFactors;            // Tessellation factors ( x=Edge, y=Inside, z=MinDistance, w=Range )
    float4      g_f4ScreenParams;           // Screen resolution ( x=Current width, y=Current height )
    float4      g_f4GUIParams1;             // GUI params1 ( x=BackFace Epsilon, y=Silhouette Epsilon, z=Range scale, w=Edge size )
    float4      g_f4GUIParams2;             // GUI params2 ( x=Screen resolution scale, y=View Frustum Epsilon )
    float4      g_f4ViewFrustumPlanes[4];   // View frustum planes ( x=left, y=right, z=top, w=bottom )
}

// Some global lighting constants
static float4 g_f4MaterialDiffuseColor  = float4( 1.0f, 1.0f, 1.0f, 1.0f );
static float4 g_f4LightDiffuse          = float4( 1.0f, 1.0f, 1.0f, 1.0f );
static float4 g_f4MaterialAmbientColor  = float4( 0.2f, 0.2f, 0.2f, 1.0f );

// Some global epsilons for adaptive tessellation
static float g_fMaxScreenWidth = 2560.0f;
static float g_fMaxScreenHeight = 1600.0f;


//--------------------------------------------------------------------------------------
// Buffers, Textures and Samplers
//--------------------------------------------------------------------------------------

// Textures
Texture2D g_txDiffuse : register( t0 );

// Samplers
SamplerState g_SamplePoint  : register( s0 );
SamplerState g_SampleLinear : register( s1 );


//--------------------------------------------------------------------------------------
// Shader structures
//--------------------------------------------------------------------------------------

struct VS_RenderSceneInput
{
    float3 f3Position   : POSITION;  
    float3 f3Normal     : NORMAL;     
    float2 f2TexCoord   : TEXCOORD;
};

struct HS_RenderSceneInput
{
    float3 f3Position   : POSITION;
    float3 f3Normal     : NORMAL;
    float2 f2TexCoord   : TEXCOORD;
};

struct HS_ConstantOutput
{
    // Tess factor for the FF HW block
    float fTessFactor[3]    : SV_TessFactor;
    float fInsideTessFactor : SV_InsideTessFactor;
    
    // Geometry cubic generated control points
	float3 f3ViewB111       : CENTER;
    
#ifdef QUADRATIC_NORMAL
    // Normal quadratic generated control points
    float3 f3N110    : NORMAL3;      
    float3 f3N011    : NORMAL4;
    float3 f3N101    : NORMAL5;
#endif
};

struct HS_ControlPointOutput
{
    float3 f3Position[3]   : POSITION;
    float3 f3Normal        : NORMAL;
    float2 f2TexCoord      : TEXCOORD;
    float fOppositeEdgeLOD : LODDATA;
    float fClipped         : CLIPPED; // 1.0 means clipped, 0.0 means unclipped
};

struct DS_Output
{
    float4 f4Position   : SV_Position;
    float2 f2TexCoord   : TEXCOORD0;
    float4 f4Diffuse    : COLOR0;
};

struct PS_RenderSceneInput
{
    float4 f4Position   : SV_Position;
    float2 f2TexCoord   : TEXCOORD0;
    float4 f4Diffuse    : COLOR0;
};

struct PS_RenderOutput
{
    float4 f4Color      : SV_Target0;
};

float3 ComputeCP(float3 posA, float3 posB, float3 normA) {
	return (2 * posA + posB - (dot((posB - posA), normA) * normA)) /
		3.0f;
}
// Expects that projMatrix is the canonical projection matrix. Will be
// faster than performing a full 4x4 matrix multiply by an eye space
// position in that case.
float4 ApplyProjection(float4x4 projMatrix, float3 eyePosition)
{
	float4 clipPos;
#if FAST_PROJECTION_XFORM
	// In the canonical projection matrix, all other elements are zero
	// and eyePosition[3] == 1.
	clipPos[0] = projMatrix[0][0] * eyePosition[0];
	clipPos[1] = projMatrix[1][1] * eyePosition[1];
	clipPos[2] = projMatrix[2][2] * eyePosition[2] + projMatrix[3][2];
	clipPos[3] = eyePosition[2];
#else
	clipPos = mul(float4(eyePosition, 1), projMatrix );
#endif

	return clipPos;
}

// This will project the input eye-space position by the specified
// matrix, then compute an incorrect (but properly scaled) window
// position. Finally, we divide by the tessellation factor,
// which is approximately how many pixels we want per-triangle.
float2 ProjectAndScale(float4x4 projMatrix, float3 inPos)
{
	float4 posClip = ApplyProjection(projMatrix, inPos);
	float2 posNDC = posClip.xy / posClip.w;

	return posNDC * g_f4ScreenParams.xy / max(1.f, g_f4GUIParams1.w);
}

float IsClipped(float4 clipPos)
{
	// Test whether the position is entirely inside the view frustum.
	return (-clipPos.w <= clipPos.x && clipPos.x <= clipPos.w
		&& -clipPos.w <= clipPos.y && clipPos.y <= clipPos.w
		&& -clipPos.w <= clipPos.z && clipPos.z <= clipPos.w)
		? 0.0f
		: 1.0f;
}

float ComputeClipping(float4x4 projMatrix, float3 cpA, float3 cpB, float3 cpC)
{
	// Compute the projected position for each position, then check to
	// see whether they are clipped.
	float4 projPosA = ApplyProjection(projMatrix, cpA),
		projPosB = ApplyProjection(projMatrix, cpB),
		projPosC = ApplyProjection(projMatrix, cpC);

	return min(min(IsClipped(projPosA), IsClipped(projPosB)),
		IsClipped(projPosC));
}
// Compute the edge LOD for the four specifed control points, which
// should be the control points along one edge of the triangle. This is
// significantly more accurate than just using the end points of the
// triangle because it takes curvature into account. Note that will
// overestimate the number of triangles needed, but typically not by
// too much. It also ensures that we never cull a triangle by ensuring
// that the LOD is at least 1.
float ComputeEdgeLOD(float4x4 projMatrix,
	float3 cpA, float3 cpB, float3 cpC, float3 cpD)
{
	float2 projCpA = ProjectAndScale(projMatrix, cpA).xy,
		projCpB = ProjectAndScale(projMatrix, cpB).xy,
		projCpC = ProjectAndScale(projMatrix, cpC).xy,
		projCpD = ProjectAndScale(projMatrix, cpD).xy;

	float edgeLOD = distance(projCpA, projCpB)
		+ distance(projCpB, projCpC)
		+ distance(projCpC, projCpD);
	return max(edgeLOD, 1);
}

//--------------------------------------------------------------------------------------
// This vertex shader computes standard transform and lighting, with no tessellation stages following
//--------------------------------------------------------------------------------------
PS_RenderSceneInput VS_RenderScene( VS_RenderSceneInput I )
{
    PS_RenderSceneInput O;
    float3 f3NormalWorldSpace;
    
    // Transform the position from object space to homogeneous projection space
    O.f4Position = mul( float4( I.f3Position, 1.0f ), g_f4x4WorldViewProjection );
    
    // Transform the normal from object space to world space    
    f3NormalWorldSpace = normalize( mul( I.f3Normal, (float3x3)g_f4x4World ) );
    
    // Calc diffuse color    
    O.f4Diffuse.rgb = g_f4MaterialDiffuseColor * g_f4LightDiffuse * max( 0, dot( f3NormalWorldSpace, g_f4LightDir.xyz ) ) + g_f4MaterialAmbientColor;  
    O.f4Diffuse.a = 1.0f;
    
    // Pass through texture coords
    O.f2TexCoord = I.f2TexCoord; 
    
    return O;    
}


//--------------------------------------------------------------------------------------
// This vertex shader is a pass through stage, with HS, tessellation, and DS stages following
//--------------------------------------------------------------------------------------
HS_RenderSceneInput VS_RenderSceneWithTessellation( VS_RenderSceneInput I )
{
    HS_RenderSceneInput O;
    
    // Pass through world space position
    O.f3Position = mul( float4(I.f3Position, 1.f), g_f4x4World ).xyz;
    
    // Pass through normalized world space normal    
    O.f3Normal = normalize( mul( I.f3Normal, (float3x3)g_f4x4World ) );
        
    // Pass through texture coordinates
    O.f2TexCoord = I.f2TexCoord;
    
    return O;    
}


//--------------------------------------------------------------------------------------
// This hull shader passes the tessellation factors through to the HW tessellator, 
// and the 10 (geometry), 6 (normal) control points of the PN-triangular patch to the domain shader
//--------------------------------------------------------------------------------------
HS_ConstantOutput HS_ConstantPN( const OutputPatch<HS_ControlPointOutput, 3> I )
{
    HS_ConstantOutput O = (HS_ConstantOutput)0;

	float3 
		f3B300 = I[0].f3Position[0],
		f3B210 = I[0].f3Position[1],
		f3B120 = I[0].f3Position[2],
		f3B030 = I[1].f3Position[0],
		f3B021 = I[1].f3Position[1],
		f3B012 = I[1].f3Position[2],
		f3B003 = I[2].f3Position[0],
		f3B102 = I[2].f3Position[1],
		f3B201 = I[2].f3Position[2];

	O.fTessFactor[0] = I[1].fOppositeEdgeLOD;
	O.fTessFactor[1] = I[2].fOppositeEdgeLOD;
	O.fTessFactor[2] = I[0].fOppositeEdgeLOD;

    // Inside tess factor is just the average of the edge factors
    O.fInsideTessFactor = max( max( O.fTessFactor[0], O.fTessFactor[1]), O.fTessFactor[2] );

	float3 f3E = (f3B210 + f3B120 + f3B021 + f3B012 + f3B102 + f3B201) / 6.0f;
	float3 f3V = (f3B003 + f3B030 + f3B300) / 3.0f;
	O.f3ViewB111 = f3E + ((f3E - f3V) / 2.0f);

#ifdef QUADRATIC_NORMAL
	// And Normals
	float3 f3N200 = I[0].f3Normal;
	float3 f3N020 = I[1].f3Normal;
	float3 f3N002 = I[2].f3Normal;

	float fV12 = 2.0f * dot(f3B030 - f3B300, f3N200 + f3N020) / dot(f3B030 - f3B300, f3B030 - f3B300);
	O.f3N110 = normalize(f3N200 + f3N020 - fV12 * (f3B030 - f3B300));
	float fV23 = 2.0f * dot(f3B003 - f3B030, f3N020 + f3N002) / dot(f3B003 - f3B030, f3B003 - f3B030);
	O.f3N011 = normalize(f3N020 + f3N002 - fV23 * (f3B003 - f3B030));
	float fV31 = 2.0f * dot(f3B300 - f3B003, f3N200 + f3N002) / dot(f3B300 - f3B003, f3B300 - f3B003);
	O.f3N101 = normalize(f3N002 + f3N200 - fV31 * (f3B300 - f3B003));
#endif


#ifdef USE_VIEW_FRUSTUM_CULLING
	float fB111Clipped = IsClipped(ApplyProjection(g_f4x4ViewProjection, O.f3ViewB111));
#else
	float fB111Clipped = 0.f;
#endif

	if (I[0].fClipped && I[1].fClipped && I[2].fClipped && fB111Clipped) 
	{ 
		O.fTessFactor[0] = 0; O.fTessFactor[1] = 0; O.fTessFactor[2] = 0; 
	}

    return O;
}

[domain("tri")]
[partitioning("fractional_odd")]
[outputtopology("triangle_cw")]
[patchconstantfunc("HS_ConstantPN")]
[outputcontrolpoints(3)]
[maxtessfactor(9)]
HS_ControlPointOutput HS_PNTriangles( 
	InputPatch<HS_RenderSceneInput, 3> I,
	uint uCPID : SV_OutputControlPointID )
{
    HS_ControlPointOutput O = (HS_ControlPointOutput)0;
    const uint NextCPID = uCPID < 2 ? uCPID + 1 : 0;
	
    // Compute all three control point
    O.f3Position[0] = I[uCPID].f3Position;
    O.f3Position[1] = ComputeCP(I[uCPID].f3Position, I[NextCPID].f3Position, I[uCPID].f3Normal);
    O.f3Position[2] = ComputeCP(I[NextCPID].f3Position, I[uCPID].f3Position, I[NextCPID].f3Normal);
    O.f3Normal = I[uCPID].f3Normal;
    O.f2TexCoord = I[uCPID].f2TexCoord;

#ifdef USE_SCREEN_SPACE_ADAPTIVE_TESSELLATION
	O.fOppositeEdgeLOD = ComputeEdgeLOD(
		g_f4x4ViewProjection, O.f3Position[0],
		O.f3Position[1], O.f3Position[2],
		I[NextCPID].f3Position
	);
#else
	O.fOppositeEdgeLOD = g_f4TessFactors.x;
#endif

#ifdef USE_VIEW_FRUSTUM_CULLING
	O.fClipped = ComputeClipping( g_f4x4Projection, O.f3Position[0], O.f3Position[1], O.f3Position[2] );
#else
	O.fClipped = 0.0f;
#endif
    
    return O;
}


//--------------------------------------------------------------------------------------
// This domain shader applies contol point weighting to the barycentric coords produced by the FF tessellator 
//--------------------------------------------------------------------------------------
[domain("tri")]
DS_Output DS_PNTriangles( HS_ConstantOutput HSConstantData, 
	const OutputPatch<HS_ControlPointOutput, 3> I,
	float3 f3BarycentricCoords : SV_DomainLocation )
{
    DS_Output O = (DS_Output)0;

    float fU = f3BarycentricCoords[0];
    float fV = f3BarycentricCoords[1];
    float fW = f3BarycentricCoords[2];

    // Precompute squares and squares * 3 
    float fUU = fU * fU;
    float fVV = fV * fV;
    float fWW = fW * fW;
    float fUU3 = fUU * 3.0f;
    float fVV3 = fVV * 3.0f;
    float fWW3 = fWW * 3.0f;
	// Although complicated, this is the canonical implementation of
	// PN, as per Vlachos, et al.
	float3 f3Position = 
		I[0].f3Position[0] * fUU * fU +
		I[1].f3Position[0] * fVV * fV +
		I[2].f3Position[0] * fWW * fW +
		I[0].f3Position[1] * fUU3 * fV +
		I[0].f3Position[2] * fVV3 * fU +
		I[1].f3Position[1] * fVV3 * fW +
		I[1].f3Position[2] * fWW3 * fV +
		I[2].f3Position[1] * fWW3 * fU +
		I[2].f3Position[2] * fUU3 * fW +
		HSConstantData.f3ViewB111 * 6.0f * fW * fU * fV;

	// In the canonical PN implementation, quadratic normals are
	// computed. However, this introduces high frequency lighting noise
	// in meshes with normals that point in the same direction but are
	// not perpendicular to the triangle surface. Moreover, quadtratic
	// normals in the face of normal maps would actually also require
	// per-pixel quadratic tangents and bitangents.
#ifdef QUADRATIC_NORMAL
    // Compute normal from quadratic control points and barycentric coords
    float3 f3Normal =   I[0].f3Normal * fUU +
                        I[1].f3Normal * fVV +
                        I[2].f3Normal * fWW +
                        HSConstantData.f3N110 * fU * fV * 2 +
                        HSConstantData.f3N011 * fV * fW * 2 +
                        HSConstantData.f3N101 * fW * fU * 2 ;
#else
	float3 f3Normal = I[0].f3Normal * fU + I[1].f3Normal * fV + I[2].f3Normal * fW;
#endif


	// Normalize the interpolated normal
	f3Normal = normalize(f3Normal);

	// Linearly interpolate the texture coords
	O.f2TexCoord = I[0].f2TexCoord * fU + I[1].f2TexCoord * fV + I[2].f2TexCoord * fW; 

	// min(I[0].fOppositeEdgeLOD, 0) will evaluate to 0 always, but the
	// compiler cannot figure that out and fOppositeEdgeLOD (and
	// fClipped) need to be used in the domain shader to avoid being
	// compiled out of the output struct.
	// This code is only here to work around a compiler bug and will be
	// removed in a future version.
	float bogusCompilerWAR = min(I[0].fOppositeEdgeLOD, 0) * I[0].fClipped;

	O.f2TexCoord.x += bogusCompilerWAR;
    // Calc diffuse color    
    O.f4Diffuse.rgb = g_f4MaterialDiffuseColor * g_f4LightDiffuse * max( 0, dot( f3Normal, g_f4LightDir.xyz ) ) + g_f4MaterialAmbientColor;  
    O.f4Diffuse.a = 1.0f; 

    // Transform model position with view-projection matrix
    O.f4Position = mul( float4( f3Position.xyz, 1.0 ), g_f4x4ViewProjection );
        
    return O;
}


//--------------------------------------------------------------------------------------
// This shader outputs the pixel's color by passing through the lit 
// diffuse material color & modulating with the diffuse texture
//--------------------------------------------------------------------------------------
PS_RenderOutput PS_RenderSceneTextured( PS_RenderSceneInput I )
{
    PS_RenderOutput O;
    
    O.f4Color = g_txDiffuse.Sample( g_SampleLinear, I.f2TexCoord ) * I.f4Diffuse;
    
    return O;
}


//--------------------------------------------------------------------------------------
// This shader outputs the pixel's color by passing through the lit 
// diffuse material color
//--------------------------------------------------------------------------------------
PS_RenderOutput PS_RenderScene( PS_RenderSceneInput I )
{
    PS_RenderOutput O;
    
    O.f4Color = I.f4Diffuse;
    
    return O;
}


//--------------------------------------------------------------------------------------
// EOF
//--------------------------------------------------------------------------------------
