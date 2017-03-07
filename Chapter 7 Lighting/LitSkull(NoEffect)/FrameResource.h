#pragma once

#include "../../Common/d3dUtil.h"
#include "../../Common/UploadBuffer.h"

struct Vertex
{
	XMFLOAT3 Pos;
	XMFLOAT3 Normal;
};

struct ObjectConstants
{
    XMMATRIX World;                    // Offset:    0, size:   64
    XMMATRIX WorldInvTranspose;        // Offset:   64, size:   64
    Material Material;                 // Offset:  128, size:   64
};

struct PassConstants
{
    DirectionalLight DirLights[3];      // Offset:    0, size:  192
	XMMATRIX ViewProj;					// Offset:	192, size:   64
    XMFLOAT3 EyePosW;                   // Offset:  256, size:   12
    FLOAT FogStart;		                // Offset:  268, size:    4
	UINT LightCount;  					// Offset:  272, size:    4
	XMFLOAT3 pad;
};

static_assert(sizeof(PassConstants) == 288, "buffer size dismatch");
static_assert(sizeof(ObjectConstants) == 192, "buffer size dismatch");

// Stores the resources needed for the CPU to build the command lists
// for a frame.  
struct FrameResource
{
public:
    FrameResource(ID3D11Device* device, UINT passCount, UINT objectCount, UINT materialCount);
    FrameResource(const FrameResource& rhs) = delete;
    FrameResource& operator=(const FrameResource& rhs) = delete;
    ~FrameResource();

    // We cannot update a cbuffer until the GPU is done processing the commands
    // that reference it.  So each frame needs their own cbuffers.
    std::unique_ptr<UploadBuffer<PassConstants>> PassCB = nullptr;
    // std::unique_ptr<UploadBuffer<MaterialConstants>> MaterialCB = nullptr;
    std::unique_ptr<UploadBuffer<ObjectConstants>> ObjectCB = nullptr;
};