// gpu_d3d11.mc - Windows gpu backend: D3D11 device, flip-model
// swapchain, one pipeline. Draws the quad batch in one call per
// frame. Each swapchain has a frame latency waitable object with max
// frame latency 1: the driver renders when it signals, so a frame is
// built when the swapchain can take it and not a refresh earlier.

private GUID IID_IDXGIFactory2 =GUID{ cast(u32, 0x50C83A1C), cast(u16, 0xE072), cast(u16, 0x4C48),
    { cast(u8, 0x87), cast(u8, 0xB0), cast(u8, 0x36), cast(u8, 0x30),
      cast(u8, 0xFA), cast(u8, 0x36), cast(u8, 0xA6), cast(u8, 0xD0) } };

private GUID IID_IDXGISwapChain2 =GUID{ cast(u32, 0xA8BE2AC4), cast(u16, 0x199F), cast(u16, 0x4946),
    { cast(u8, 0xB3), cast(u8, 0x31), cast(u8, 0x79), cast(u8, 0x59),
      cast(u8, 0x9F), cast(u8, 0xB9), cast(u8, 0x8D), cast(u8, 0xE7) } };

private GUID IID_IDXGIDevice1 =GUID{ cast(u32, 0x77DB970F), cast(u16, 0x6276), cast(u16, 0x48BA),
    { cast(u8, 0xBA), cast(u8, 0x28), cast(u8, 0x07), cast(u8, 0x01),
      cast(u8, 0x43), cast(u8, 0xB4), cast(u8, 0x39), cast(u8, 0x2C) } };

private GUID IID_ID3D11Texture2D =GUID{ cast(u32, 0x6F15AAF2), cast(u16, 0xD208), cast(u16, 0x4E89),
    { cast(u8, 0x9A), cast(u8, 0xB4), cast(u8, 0x48), cast(u8, 0x95),
      cast(u8, 0x35), cast(u8, 0xD3), cast(u8, 0x4F), cast(u8, 0x9C) } };

// --- COM interface slices (padded vtables, only the slots we call) ---
// Slot positions follow the Windows SDK headers; extend by counting
// slots there.

struct IUnknownVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
}

struct IUnknown {
    IUnknownVtbl* lpVtbl;
}

struct ID3D10BlobVtbl {
    void* _pad0;
    void* _pad1;
    fn(void*): u32 Release;
    fn(void*): void* GetBufferPointer;
    fn(void*): i64 GetBufferSize;
}

struct ID3D10Blob {
    ID3D10BlobVtbl* lpVtbl;
}

struct ID3D11DeviceVtbl {
    fn(void*, void*, void**): i32 QueryInterface;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    fn(void*, D3D11_BUFFER_DESC*, D3D11_SUBRESOURCE_DATA*, void**): i32 CreateBuffer;
    void* _pad4;
    fn(void*, D3D11_TEXTURE2D_DESC*, D3D11_SUBRESOURCE_DATA*, void**): i32 CreateTexture2D;
    void* _pad6;
    fn(void*, void*, void*, void**): i32 CreateShaderResourceView;
    void* _pad8;
    fn(void*, void*, void*, void**): i32 CreateRenderTargetView;
    void* _pad10;
    fn(void*, D3D11_INPUT_ELEMENT_DESC*, u32, void*, i64, void**): i32 CreateInputLayout;
    fn(void*, void*, i64, void*, void**): i32 CreateVertexShader;
    void* _pad13;
    void* _pad14;
    fn(void*, void*, i64, void*, void**): i32 CreatePixelShader;
    void* _pad16;
    void* _pad17;
    void* _pad18;
    void* _pad19;
    fn(void*, D3D11_BLEND_DESC*, void**): i32 CreateBlendState;
    void* _pad21;
    fn(void*, D3D11_RASTERIZER_DESC*, void**): i32 CreateRasterizerState;
    fn(void*, D3D11_SAMPLER_DESC*, void**): i32 CreateSamplerState;
}

struct ID3D11Device {
    ID3D11DeviceVtbl* lpVtbl;
}

struct ID3D11DeviceContextVtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    fn(void*, u32, u32, void*): void VSSetConstantBuffers;
    fn(void*, u32, u32, void*): void PSSetShaderResources;
    fn(void*, void*, void*, u32): void PSSetShader;
    fn(void*, u32, u32, void*): void PSSetSamplers;
    fn(void*, void*, void*, u32): void VSSetShader;
    fn(void*, u32, u32, i32): void DrawIndexed;
    fn(void*, u32, u32): void Draw;
    fn(void*, void*, u32, i32, u32, D3D11_MAPPED_SUBRESOURCE*): i32 Map;
    fn(void*, void*, u32): void Unmap;
    fn(void*, u32, u32, void*): void PSSetConstantBuffers;
    fn(void*, void*): void IASetInputLayout;
    fn(void*, u32, u32, void*, u32*, u32*): void IASetVertexBuffers;
    fn(void*, void*, i32, u32): void IASetIndexBuffer;
    void* _pad20;
    void* _pad21;
    void* _pad22;
    void* _pad23;
    fn(void*, i32): void IASetPrimitiveTopology;
    void* _pad25;
    void* _pad26;
    void* _pad27;
    void* _pad28;
    void* _pad29;
    void* _pad30;
    void* _pad31;
    void* _pad32;
    fn(void*, u32, void*, void*): void OMSetRenderTargets;
    void* _pad34;
    fn(void*, void*, f32*, u32): void OMSetBlendState;
    fn(void*, void*, u32): void OMSetDepthStencilState;
    void* _pad37;
    void* _pad38;
    void* _pad39;
    void* _pad40;
    void* _pad41;
    void* _pad42;
    fn(void*, void*): void RSSetState;
    fn(void*, u32, D3D11_VIEWPORT*): void RSSetViewports;
    void* _pad45;
    void* _pad46;
    fn(void*, void*, void*): void CopyResource;
    fn(void*, void*, u32, void*, void*, u32, u32): void UpdateSubresource;
    void* _pad49;
    fn(void*, void*, f32*): void ClearRenderTargetView;
    void* _pad51;
    void* _pad52;
    void* _pad53;
    fn(void*, void*): void GenerateMips;
}

struct ID3D11DeviceContext {
    ID3D11DeviceContextVtbl* lpVtbl;
}

struct IDXGISwapChainVtbl {
    fn(void*, void*, void**): i32 QueryInterface;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    void* _pad7;
    fn(void*, u32, u32): i32 Present;
    fn(void*, u32, void*, void**): i32 GetBuffer;
    void* _pad10;
    void* _pad11;
    void* _pad12;
    fn(void*, u32, u32, u32, i32, u32): i32 ResizeBuffers;
    void* _pad14;
    void* _pad15;
    fn(void*, DXGI_FRAME_STATISTICS*): i32 GetFrameStatistics;
    fn(void*, u32*): i32 GetLastPresentCount;
}

struct IDXGISwapChain {
    IDXGISwapChainVtbl* lpVtbl;
}

struct DXGI_FRAME_STATISTICS {
    u32 PresentCount;
    u32 PresentRefreshCount;
    u32 SyncRefreshCount;
    i64 SyncQPCTime;
    i64 SyncGPUTime;
}

// IDXGISwapChain2: slots 0-30 are IDXGISwapChain1's
struct IDXGISwapChain2Vtbl {
    u64[31] _pad;
    fn(void*, u32): i32 SetMaximumFrameLatency;
    void* _pad32;
    fn(void*): void* GetFrameLatencyWaitableObject;
}

struct IDXGISwapChain2 {
    IDXGISwapChain2Vtbl* lpVtbl;
}

struct IDXGIDevice1Vtbl {
    void* _pad0;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    void* _pad7;
    void* _pad8;
    void* _pad9;
    void* _pad10;
    void* _pad11;
    fn(void*, u32): i32 SetMaximumFrameLatency;
}

struct IDXGIDevice1 {
    IDXGIDevice1Vtbl* lpVtbl;
}

struct IDXGIFactory2Vtbl {
    fn(void*, void*, void**): i32 QueryInterface;
    fn(void*): u32 AddRef;
    fn(void*): u32 Release;
    void* _pad3;
    void* _pad4;
    void* _pad5;
    void* _pad6;
    void* _pad7;
    fn(void*, HWND, u32): i32 MakeWindowAssociation;
    void* _pad9;
    void* _pad10;
    void* _pad11;
    void* _pad12;
    void* _pad13;
    void* _pad14;
    fn(void*, void*, HWND, DXGI_SWAP_CHAIN_DESC1*, void*, void*, void**): i32 CreateSwapChainForHwnd;
}

struct IDXGIFactory2 {
    IDXGIFactory2Vtbl* lpVtbl;
}

// --- descriptor structs ----------------------------------------------

struct DXGI_SAMPLE_DESC {
    u32 Count;
    u32 Quality;
}

struct DXGI_SWAP_CHAIN_DESC1 {
    u32 Width;
    u32 Height;
    i32 Format;
    i32 Stereo;
    DXGI_SAMPLE_DESC SampleDesc;
    u32 BufferUsage;
    u32 BufferCount;
    i32 Scaling;
    i32 SwapEffect;
    i32 AlphaMode;
    u32 Flags;
}

struct D3D11_BUFFER_DESC {
    u32 ByteWidth;
    i32 Usage;
    u32 BindFlags;
    u32 CPUAccessFlags;
    u32 MiscFlags;
    u32 StructureByteStride;
}

struct D3D11_TEXTURE2D_DESC {
    u32 Width;
    u32 Height;
    u32 MipLevels;
    u32 ArraySize;
    i32 Format;
    DXGI_SAMPLE_DESC SampleDesc;
    i32 Usage;
    u32 BindFlags;
    u32 CPUAccessFlags;
    u32 MiscFlags;
}

struct D3D11_SUBRESOURCE_DATA {
    void* pSysMem;
    u32 SysMemPitch;
    u32 SysMemSlicePitch;
}

struct D3D11_MAPPED_SUBRESOURCE {
    void* pData;
    u32 RowPitch;
    u32 DepthPitch;
}

struct D3D11_VIEWPORT {
    f32 TopLeftX;
    f32 TopLeftY;
    f32 Width;
    f32 Height;
    f32 MinDepth;
    f32 MaxDepth;
}

struct D3D11_RENDER_TARGET_BLEND_DESC {
    i32 BlendEnable;
    i32 SrcBlend;
    i32 DestBlend;
    i32 BlendOp;
    i32 SrcBlendAlpha;
    i32 DestBlendAlpha;
    i32 BlendOpAlpha;
    u8 RenderTargetWriteMask;
}

struct D3D11_BLEND_DESC {
    i32 AlphaToCoverageEnable;
    i32 IndependentBlendEnable;
    D3D11_RENDER_TARGET_BLEND_DESC[8] RenderTarget;
}

struct D3D11_RASTERIZER_DESC {
    i32 FillMode;
    i32 CullMode;
    i32 FrontCounterClockwise;
    i32 DepthBias;
    f32 DepthBiasClamp;
    f32 SlopeScaledDepthBias;
    i32 DepthClipEnable;
    i32 ScissorEnable;
    i32 MultisampleEnable;
    i32 AntialiasedLineEnable;
}

struct D3D11_SAMPLER_DESC {
    i32 Filter;
    i32 AddressU;
    i32 AddressV;
    i32 AddressW;
    f32 MipLODBias;
    u32 MaxAnisotropy;
    i32 ComparisonFunc;
    f32[4] BorderColor;
    f32 MinLOD;
    f32 MaxLOD;
}

struct D3D11_INPUT_ELEMENT_DESC {
    u8* SemanticName;
    u32 SemanticIndex;
    i32 Format;
    u32 InputSlot;
    u32 AlignedByteOffset;
    i32 InputSlotClass;
    u32 InstanceDataStepRate;
}

extern "d3d11.dll" i32 D3D11CreateDevice(void* adapter, i32 driverType, void* software, u32 flags, void* featureLevels, u32 numLevels, u32 sdkVersion, void** device, i32* featureLevel, void** context);
extern "dxgi.dll" i32 CreateDXGIFactory1(void* riid, void** factory);

type PD3DCompile = fn(void*, i64, u8*, void*, void*, u8*, u8*, u32, u32, void**, void**): i32;

const i32 DXGI_FORMAT_R32G32_FLOAT = 16;
const i32 DXGI_FORMAT_R8G8B8A8_UNORM = 28;
const i32 DXGI_FORMAT_R8_UNORM = 61;
const i32 DXGI_FORMAT_B8G8R8A8_UNORM = 87;
const i32 DXGI_SWAP_EFFECT_FLIP_DISCARD = 4;
const i32 DXGI_SCALING_NONE = 1;
const u32 DXGI_USAGE_RENDER_TARGET_OUTPUT = 0x20;

const i32 D3D_DRIVER_TYPE_HARDWARE = 1;
const u32 D3D11_SDK_VERSION = 7;
const i32 D3D11_USAGE_DEFAULT = 0;
const i32 D3D11_USAGE_IMMUTABLE = 1;
const i32 D3D11_USAGE_DYNAMIC = 2;
const u32 D3D11_BIND_VERTEX_BUFFER = 1;
const u32 D3D11_BIND_SHADER_RESOURCE = 8;
const u32 D3D11_BIND_CONSTANT_BUFFER = 4;
const u32 D3D11_CPU_ACCESS_WRITE = 0x10000;
const i32 D3D11_MAP_WRITE_DISCARD = 4;
// readback for --shot
const i32 D3D11_USAGE_STAGING = 3;
const u32 D3D11_CPU_ACCESS_READ = 0x20000;
const i32 D3D11_MAP_READ = 1;
const i32 D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST = 4;
const i32 D3D11_FILL_SOLID = 3;
const i32 D3D11_CULL_NONE = 1;
const i32 D3D11_BLEND_ZERO = 1;
const i32 D3D11_BLEND_ONE = 2;
const i32 D3D11_BLEND_SRC_ALPHA = 5;
const i32 D3D11_BLEND_INV_SRC_ALPHA = 6;
const i32 D3D11_BLEND_SRC1_COLOR = 16;
const i32 D3D11_BLEND_INV_SRC1_COLOR = 17;
const i32 D3D11_BLEND_OP_ADD = 1;
const i32 D3D11_FILTER_MIN_MAG_MIP_POINT = 0;
const i32 D3D11_FILTER_MIN_LINEAR_MAG_POINT_MIP_LINEAR = 0x11;
const i32 D3D11_FILTER_MIN_MAG_MIP_LINEAR = 0x15;
private const u32 D3D11_BIND_RENDER_TARGET = 0x20;
private const u32 D3D11_RESOURCE_MISC_GENERATE_MIPS = 0x1;
private const f32 D3D11_FLOAT32_MAX = 3.402823466e+38f;
private const i32 GPU_IMAGE_MAX = 64;
private const i32 GPU_IMAGE_SIDE_MAX = 16384;   // D3D11's largest 2D texture
const i32 D3D11_TEXTURE_ADDRESS_CLAMP = 3;
const u32 DXGI_MWA_NO_ALT_ENTER = 2;

private const u32 GPU_CBUF_SIZE = 32;  // float2 screen, float2 shift, float4 bg color

// --- state -----------------------------------------------------------

private ID3D11Device* gpu_dev = null;
private ID3D11DeviceContext* gpu_ctx = null;

// One swapchain per window; the device, context, shaders and atlas are
// shared. gpu_bound selects which surface the frame path targets.
private const i32 GPU_WIN_MAX = 8;
private struct GpuSurf {
    IDXGISwapChain* sc;
    void* rtv;
    void* wait;     // the frame latency waitable object, or null
    u32 flags;      // the creation flags, which ResizeBuffers must repeat
    i32 w;
    i32 h;
    bool used;
}

private const u32 DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT = 0x40;
// false: swapchains have no waitable object, and Present blocks under
// the device's max frame latency (EDMINC_WAITABLE=0, for comparison)
bool gpu_waitable = true;
private GpuSurf[GPU_WIN_MAX] gpu_surf;
private i32 gpu_bound = 0;
private void* gpu_vs = null;
private void* gpu_ps = null;
private void* gpu_layout = null;
private void* gpu_vbuf = null;
private void* gpu_cbuf = null;
private void* gpu_blend = null;
private void* gpu_raster = null;
private void* gpu_sampler = null;
private void* gpu_img_smooth = null;    // an image: linear, through its mip levels
private void* gpu_img_blocks = null;    // magnified as blocks, reduced as smooth

// the images: a texture with its full mip chain, and its view
private struct GpuImage {
    void* tex;
    void* srv;
    bool used;
}
private GpuImage[GPU_IMAGE_MAX] gpu_images;
private void* gpu_atlas_tex = null;
private void* gpu_atlas_srv = null;

// one line per stage; HLSL does not need newlines.
// Text blending, DirectWrite style: TEXT_CONTRAST steepens edge
// coverage (a + k*a*(1-a)), then the blend result is computed in
// gamma space against the known background color and converted back
// to an effective coverage for the fixed-function dual-source blend.
// This scales the correction with each token color's luminance, so
// dim text (comments) does not over-brighten. Values tuned with
// scripts/pixcmp against the reference editor; retune there if
// either changes.
// The pixel shader emits two outputs: o0 is the text color, o1 the
// per-channel coverage; dst = o0 * o1 + dst * (1 - o1) per channel.
// Full coverage is full opacity: the formula divides by the distance
// from the background, so a quad in the background's own color would
// otherwise draw nothing, and a solid rect in that color over another
// color (a tile's ground in the explode view) would not show.
// A color glyph (color emoji) is signalled by a fully clear vertex
// color (col.a == 0, which no real draw uses): its atlas cell is
// straight RGBA, so the shader outputs o0 = rgb, o1 = a and the same
// blend composites it "over", skipping the coverage/gamma math.
private u8* GPU_SHADER_SRC = "static const float TEXT_CONTRAST = 0.5; static const float TEXT_GAMMA = 1.55;cbuffer C : register(b0) { float2 screen; float2 shift; float4 bgcol; } struct VSIn { float2 pos : POS; float2 uv : UV; float4 col : COL; }; struct VSOut { float4 pos : SV_Position; float2 uv : UV; float4 col : COL; }; struct PSOut { float4 col : SV_Target0; float4 cov : SV_Target1; }; Texture2D tex : register(t0); SamplerState smp : register(s0); VSOut vsmain(VSIn i) { VSOut o; o.pos = float4(i.pos.x * 2.0 / screen.x - 1.0, 1.0 - (i.pos.y + shift.y) * 2.0 / screen.y, 0.0, 1.0); o.uv = i.uv; o.col = i.col; return o; } PSOut psmain(VSOut i) { PSOut o; if (bgcol.w > 0.5) { float2 ui = float2(i.uv.x < 0.0 ? -i.uv.x - 1.0 : i.uv.x, i.uv.y); float4 ti = tex.Sample(smp, ui); float ai = ti.a * i.col.a; o.col = float4(ti.rgb, 1.0); o.cov = float4(ai, ai, ai, 1.0); return o; } bool sc = i.uv.x < 0.0; float2 uv = float2(sc ? -i.uv.x - 1.0 : i.uv.x, i.uv.y); float2 fw = fwidth(uv); float4 t = tex.SampleLevel(smp, uv, 0); if (sc) { t = float4(0.0, 0.0, 0.0, 0.0); for (int k = 0; k < 9; k++) { t += tex.SampleLevel(smp, uv + float2(float(k % 3) - 1.0, float(k / 3) - 1.0) * fw * 0.33, 0); } t = t / 9.0; } if (i.col.a == 0.0) { o.col = float4(t.rgb, 1.0); o.cov = float4(t.a, t.a, t.a, 1.0); return o; } float3 a = t.rgb; a = a + TEXT_CONTRAST * a * (1.0 - a); float3 og = pow(pow(i.col.rgb, TEXT_GAMMA) * a + pow(bgcol.rgb, TEXT_GAMMA) * (1.0 - a), 1.0 / TEXT_GAMMA); float3 dn = i.col.rgb - bgcol.rgb; float3 sg = step(0.0, dn) * 2.0 - 1.0; float3 aeff = saturate((og - bgcol.rgb) / (sg * max(abs(dn), 0.004))); aeff = max(aeff, step(1.0, a)); o.col = float4(i.col.rgb, 1.0); o.cov = float4(aeff * i.col.a, 1.0); return o; }";

private void* gpu_compile(PD3DCompile compile, u8* entry, u8* target) {
    u8* src = GPU_SHADER_SRC;
    i64 srclen = 0;
    while src[srclen] != 0 { srclen++; }
    void* blob = null;
    void* err = null;
    i32 hr = compile(src, srclen, "edminc", null, null, entry, target, 0, 0, &blob, &err);
    if hr < 0 {
        if err != null {
            ID3D10Blob* eb = cast(ID3D10Blob*, err);
            u8* msg = cast(u8*, eb.lpVtbl.GetBufferPointer(eb));
            print("shader compile failed: {}\n", str_from_cstr(msg));
        }
        exit(1);
    }
    return blob;
}

private void gpu_create_rtv() {
    GpuSurf* s = &gpu_surf[gpu_bound];
    void* backbuf = null;
    if s.sc.lpVtbl.GetBuffer(s.sc, 0, &IID_ID3D11Texture2D, &backbuf) < 0 { return; }
    ignore gpu_dev.lpVtbl.CreateRenderTargetView(gpu_dev, backbuf, null, &s.rtv);
    IUnknown* bb = cast(IUnknown*, backbuf);
    ignore bb.lpVtbl.Release(bb);
}

// a swapchain + rtv for a window, into a free slot; returns its index
private i32 gpu_surf_new(HWND hwnd, i32 w, i32 h) {
    i32 id = -1;
    for i32 i = 0; i < GPU_WIN_MAX; i++ {
        if !gpu_surf[i].used { id = i; break; }
    }
    if id < 0 { return -1; }
    void* factory = null;
    if CreateDXGIFactory1(&IID_IDXGIFactory2, &factory) < 0 { return -1; }
    IDXGIFactory2* fac = cast(IDXGIFactory2*, factory);
    DXGI_SWAP_CHAIN_DESC1 scd;
    scd.Width = cast(u32, w);
    scd.Height = cast(u32, h);
    scd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    scd.SampleDesc.Count = 1;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.BufferCount = 2;
    scd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    // During a live resize the compositor can show a frame of the
    // previous size. Unscaled, it sits at the top left; stretched, its
    // text moves with every step of the drag.
    scd.Scaling = DXGI_SCALING_NONE;
    if gpu_waitable { scd.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT; }
    void* sc = null;
    i32 hr = fac.lpVtbl.CreateSwapChainForHwnd(fac, gpu_dev, hwnd, &scd, null, null, &sc);
    if hr < 0 {
        // without the waitable object, Present blocks under the
        // device's max frame latency instead
        scd.Flags = 0;
        hr = fac.lpVtbl.CreateSwapChainForHwnd(fac, gpu_dev, hwnd, &scd, null, null, &sc);
    }
    if hr >= 0 { ignore fac.lpVtbl.MakeWindowAssociation(fac, hwnd, DXGI_MWA_NO_ALT_ENTER); }
    ignore fac.lpVtbl.Release(fac);
    if hr < 0 { return -1; }
    gpu_surf[id].sc = cast(IDXGISwapChain*, sc);
    gpu_surf[id].rtv = null;
    gpu_surf[id].wait = null;
    gpu_surf[id].flags = scd.Flags;
    if scd.Flags != 0 {
        IDXGISwapChain* sc0 = cast(IDXGISwapChain*, sc);
        void* sc2 = null;
        if sc0.lpVtbl.QueryInterface(sc0, &IID_IDXGISwapChain2, &sc2) >= 0 {
            IDXGISwapChain2* s2 = cast(IDXGISwapChain2*, sc2);
            ignore s2.lpVtbl.SetMaximumFrameLatency(s2, 1);
            gpu_surf[id].wait = s2.lpVtbl.GetFrameLatencyWaitableObject(s2);
            IUnknown* s2u = cast(IUnknown*, sc2);
            ignore s2u.lpVtbl.Release(s2u);
        }
    }
    gpu_surf[id].w = w;
    gpu_surf[id].h = h;
    gpu_surf[id].used = true;
    i32 save = gpu_bound;
    gpu_bound = id;
    gpu_create_rtv();
    gpu_bound = save;
    return id;
}

// a window's swapchain; the driver pairs it with a native window
i32 gpu_win_create(HWND hwnd, i32 w, i32 h) {
    return gpu_surf_new(hwnd, w, h);
}

// select the surface the frame path targets
void gpu_bind(i32 id) {
    if id >= 0 && id < GPU_WIN_MAX && gpu_surf[id].used { gpu_bound = id; }
}

void gpu_win_destroy(i32 id) {
    if id < 0 || id >= GPU_WIN_MAX || !gpu_surf[id].used { return; }
    GpuSurf* s = &gpu_surf[id];
    if s.rtv != null {
        IUnknown* r = cast(IUnknown*, s.rtv);
        ignore r.lpVtbl.Release(r);
        s.rtv = null;
    }
    if s.sc != null {
        IUnknown* c = cast(IUnknown*, s.sc);
        ignore c.lpVtbl.Release(c);
        s.sc = null;
    }
    if s.wait != null {
        ignore win_close_handle(s.wait);
        s.wait = null;
    }
    s.used = false;
}

// the surface's frame latency waitable object, or null
void* gpu_wait_handle(i32 id) {
    if id < 0 || id >= GPU_WIN_MAX || !gpu_surf[id].used { return null; }
    return gpu_surf[id].wait;
}

// the surface's present count after its last Present
u32 gpu_last_present(i32 id) {
    if id < 0 || id >= GPU_WIN_MAX || !gpu_surf[id].used { return 0; }
    GpuSurf* s = &gpu_surf[id];
    u32 n = 0;
    ignore s.sc.lpVtbl.GetLastPresentCount(s.sc, &n);
    return n;
}

// the surface's most recent present on screen: its present count, the
// refresh count that showed it, and a refresh count with its QPC time
bool gpu_frame_stats(i32 id, u32* present, u32* shown, u32* sync, i64* qpc) {
    if id < 0 || id >= GPU_WIN_MAX || !gpu_surf[id].used { return false; }
    GpuSurf* s = &gpu_surf[id];
    DXGI_FRAME_STATISTICS st;
    if s.sc.lpVtbl.GetFrameStatistics(s.sc, &st) < 0 { return false; }
    present[0] = st.PresentCount;
    shown[0] = st.PresentRefreshCount;
    sync[0] = st.SyncRefreshCount;
    qpc[0] = st.SyncQPCTime;
    return true;
}

// Flip-model Present unbinds the back buffer, so releasing our RTV
// reference is enough for ResizeBuffers to succeed between frames.
void gpu_resize(i32 w, i32 h) {
    GpuSurf* s = &gpu_surf[gpu_bound];
    if s.sc == null || w <= 0 || h <= 0 { return; }
    if w == s.w && h == s.h { return; }
    s.w = w;
    s.h = h;
    if s.rtv != null {
        IUnknown* rtv = cast(IUnknown*, s.rtv);
        ignore rtv.lpVtbl.Release(rtv);
        s.rtv = null;
    }
    ignore s.sc.lpVtbl.ResizeBuffers(s.sc, 0, cast(u32, w), cast(u32, h), 0, s.flags);
    gpu_create_rtv();
}

bool gpu_init(HWND hwnd, i32 w, i32 h) {
    void* dev = null;
    void* ctx = null;
    i32 flevel = 0;
    i32 hr = D3D11CreateDevice(null, D3D_DRIVER_TYPE_HARDWARE, null, 0, null, 0, D3D11_SDK_VERSION, &dev, &flevel, &ctx);
    if hr < 0 {
        print("D3D11CreateDevice failed: {}\n", hr);
        return false;
    }
    gpu_dev = cast(ID3D11Device*, dev);
    gpu_ctx = cast(ID3D11DeviceContext*, ctx);

    // Frame latency 1: at most one queued frame between input and photon.
    void* dxdev = null;
    if gpu_dev.lpVtbl.QueryInterface(gpu_dev, &IID_IDXGIDevice1, &dxdev) >= 0 {
        IDXGIDevice1* dd = cast(IDXGIDevice1*, dxdev);
        ignore dd.lpVtbl.SetMaximumFrameLatency(dd, 1);
        IUnknown* ddu = cast(IUnknown*, dxdev);
        ignore ddu.lpVtbl.Release(ddu);
    }

    if gpu_surf_new(hwnd, w, h) != 0 {
        print("primary swapchain failed\n");
        return false;
    }
    gpu_bound = 0;

    // Shaders.
    void* dll = LoadLibraryA("d3dcompiler_47.dll");
    if dll == null {
        print("d3dcompiler_47.dll not found\n");
        return false;
    }
    PD3DCompile compile = cast(PD3DCompile, GetProcAddress(dll, "D3DCompile"));
    void* vsb = gpu_compile(compile, "vsmain", "vs_5_0");
    void* psb = gpu_compile(compile, "psmain", "ps_5_0");
    ID3D10Blob* vb = cast(ID3D10Blob*, vsb);
    ID3D10Blob* pb = cast(ID3D10Blob*, psb);
    ignore gpu_dev.lpVtbl.CreateVertexShader(gpu_dev, vb.lpVtbl.GetBufferPointer(vb), vb.lpVtbl.GetBufferSize(vb), null, &gpu_vs);
    ignore gpu_dev.lpVtbl.CreatePixelShader(gpu_dev, pb.lpVtbl.GetBufferPointer(pb), pb.lpVtbl.GetBufferSize(pb), null, &gpu_ps);

    D3D11_INPUT_ELEMENT_DESC[3] elems;
    elems[0] = D3D11_INPUT_ELEMENT_DESC{ "POS", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, 0, 0 };
    elems[1] = D3D11_INPUT_ELEMENT_DESC{ "UV", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, 0, 0 };
    elems[2] = D3D11_INPUT_ELEMENT_DESC{ "COL", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 16, 0, 0 };
    hr = gpu_dev.lpVtbl.CreateInputLayout(gpu_dev, &elems[0], 3, vb.lpVtbl.GetBufferPointer(vb), vb.lpVtbl.GetBufferSize(vb), &gpu_layout);
    if hr < 0 {
        print("CreateInputLayout failed: {}\n", hr);
        return false;
    }
    ignore vb.lpVtbl.Release(vb);
    ignore pb.lpVtbl.Release(pb);

    // Dynamic vertex buffer sized for the shared batch.
    D3D11_BUFFER_DESC bd;
    bd.ByteWidth = cast(u32, DRAW_MAX_VERTS * sizeof(DrawVtx));
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = gpu_dev.lpVtbl.CreateBuffer(gpu_dev, &bd, null, &gpu_vbuf);
    if hr < 0 {
        print("CreateBuffer(vertex) failed: {}\n", hr);
        return false;
    }

    D3D11_BUFFER_DESC cbd;
    cbd.ByteWidth = GPU_CBUF_SIZE;
    cbd.Usage = D3D11_USAGE_DYNAMIC;
    cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = gpu_dev.lpVtbl.CreateBuffer(gpu_dev, &cbd, null, &gpu_cbuf);
    if hr < 0 {
        print("CreateBuffer(const) failed: {}\n", hr);
        return false;
    }

    // dual-source: o1 carries per-channel coverage for subpixel text
    D3D11_BLEND_DESC bld;
    bld.RenderTarget[0].BlendEnable = 1;
    bld.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC1_COLOR;
    bld.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC1_COLOR;
    bld.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    bld.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    bld.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
    bld.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bld.RenderTarget[0].RenderTargetWriteMask = 0x0F;
    ignore gpu_dev.lpVtbl.CreateBlendState(gpu_dev, &bld, &gpu_blend);

    D3D11_RASTERIZER_DESC rd;
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = 1;
    ignore gpu_dev.lpVtbl.CreateRasterizerState(gpu_dev, &rd, &gpu_raster);

    D3D11_SAMPLER_DESC sd;
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    ignore gpu_dev.lpVtbl.CreateSamplerState(gpu_dev, &sd, &gpu_sampler);
    // the images' two: through every mip level
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    ignore gpu_dev.lpVtbl.CreateSamplerState(gpu_dev, &sd, &gpu_img_smooth);
    sd.Filter = D3D11_FILTER_MIN_LINEAR_MAG_POINT_MIP_LINEAR;
    ignore gpu_dev.lpVtbl.CreateSamplerState(gpu_dev, &sd, &gpu_img_blocks);

    // Glyph atlas texture (updated from CPU when new glyphs land).
    D3D11_TEXTURE2D_DESC td;
    td.Width = ATLAS_W;
    td.Height = ATLAS_H;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    ignore gpu_dev.lpVtbl.CreateTexture2D(gpu_dev, &td, null, &gpu_atlas_tex);
    ignore gpu_dev.lpVtbl.CreateShaderResourceView(gpu_dev, gpu_atlas_tex, null, &gpu_atlas_srv);

    return true;
}

void gpu_upload_atlas(u8* pixels) {
    gpu_ctx.lpVtbl.UpdateSubresource(gpu_ctx, gpu_atlas_tex, 0, null, pixels, cast(u32, ATLAS_W * 4), 0);
}

// An image as a texture of its own: straight RGBA8, w by h, its mip
// levels made on the gpu. The handle, or -1 when the device refuses it
// or the table is full.
i32 gpu_image_create(u8* rgba, i32 w, i32 h) {
    if gpu_dev == null || w <= 0 || h <= 0 || w > GPU_IMAGE_SIDE_MAX || h > GPU_IMAGE_SIDE_MAX { return -1; }
    i32 slot = -1;
    for i32 i = 0; i < GPU_IMAGE_MAX; i++ {
        if !gpu_images[i].used {
            slot = i;
            break;
        }
    }
    if slot < 0 { return -1; }
    D3D11_TEXTURE2D_DESC td;
    td.Width = cast(u32, w);
    td.Height = cast(u32, h);
    td.MipLevels = 0;   // the full chain
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    // GenerateMips renders the levels, so the texture is a render target too
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    td.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
    void* tex = null;
    if gpu_dev.lpVtbl.CreateTexture2D(gpu_dev, &td, null, &tex) < 0 { return -1; }
    void* srv = null;
    if gpu_dev.lpVtbl.CreateShaderResourceView(gpu_dev, tex, null, &srv) < 0 {
        IUnknown* t = cast(IUnknown*, tex);
        ignore t.lpVtbl.Release(t);
        return -1;
    }
    gpu_ctx.lpVtbl.UpdateSubresource(gpu_ctx, tex, 0, null, rgba, cast(u32, w * 4), 0);
    gpu_ctx.lpVtbl.GenerateMips(gpu_ctx, srv);
    gpu_images[slot] = GpuImage{ tex, srv, true };
    return slot;
}

void gpu_image_free(i32 h) {
    if h < 0 || h >= GPU_IMAGE_MAX || !gpu_images[h].used { return; }
    IUnknown* v = cast(IUnknown*, gpu_images[h].srv);
    ignore v.lpVtbl.Release(v);
    IUnknown* t = cast(IUnknown*, gpu_images[h].tex);
    ignore t.lpVtbl.Release(t);
    gpu_images[h] = GpuImage{ null, null, false };
}

// --shot: read the frame back and write it as a PPM, for automated
// pixel validation. Same contract as the GL and Metal backends.
private bool shot_on = false;
private u8[1024] shot_path;
private i32 shot_path_len = 0;

void gpu_request_shot(str p) {
    if p.len > 1023 { return; }
    memcpy(&shot_path[0], p.data, p.len);
    shot_path_len = p.len;
    shot_on = true;
}

// Copy the back buffer into a staging texture and read it. This has to
// happen before Present: the flip model hands the buffer to the
// compositor there, and its contents are undefined afterwards.
private void gpu_do_shot() {
    GpuSurf* s = &gpu_surf[gpu_bound];
    i32 gpu_width = s.w;
    i32 gpu_height = s.h;
    if gpu_width <= 0 || gpu_height <= 0 { return; }
    void* backbuf = null;
    if s.sc.lpVtbl.GetBuffer(s.sc, 0, &IID_ID3D11Texture2D, &backbuf) < 0 {
        return;
    }
    D3D11_TEXTURE2D_DESC td;
    td.Width = cast(u32, gpu_width);
    td.Height = cast(u32, gpu_height);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_STAGING;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    void* stage = null;
    IUnknown* bb = cast(IUnknown*, backbuf);
    if gpu_dev.lpVtbl.CreateTexture2D(gpu_dev, &td, null, &stage) < 0 {
        ignore bb.lpVtbl.Release(bb);
        return;
    }
    gpu_ctx.lpVtbl.CopyResource(gpu_ctx, stage, backbuf);
    D3D11_MAPPED_SUBRESOURCE ms;
    IUnknown* st = cast(IUnknown*, stage);
    if gpu_ctx.lpVtbl.Map(gpu_ctx, stage, 0, D3D11_MAP_READ, 0, &ms) >= 0 {
        i64 n = cast(i64, gpu_width) * cast(i64, gpu_height);
        u8* out = alloc<u8>(n * 3 + 64);
        i32 hn = ppm_header(out, gpu_width, gpu_height);
        // the swapchain is BGRA and the rows are RowPitch apart, which
        // is not the same as the width
        u8* src = cast(u8*, ms.pData);
        for i32 y = 0; y < gpu_height; y++ {
            u8* row = src + cast(i64, y) * cast(i64, ms.RowPitch);
            i64 dst = cast(i64, hn) + cast(i64, y) * cast(i64, gpu_width) * 3;
            for i32 x = 0; x < gpu_width; x++ {
                out[dst] = row[x * 4 + 2];
                out[dst + 1] = row[x * 4 + 1];
                out[dst + 2] = row[x * 4];
                dst += 3;
            }
        }
        gpu_ctx.lpVtbl.Unmap(gpu_ctx, stage, 0);
        FileData fd;
        fd.data = out;
        fd.len = cast(i32, cast(i64, hn) + n * 3);
        ignore file_write(str_from(&shot_path[0], shot_path_len), fd);
        free(out);
    }
    ignore st.lpVtbl.Release(st);
    ignore bb.lpVtbl.Release(bb);
}

// the shader's constants: the surface, the caption shift, the
// background, and whether the run is an image
private void gpu_cbuf_set(GpuSurf* s, f32 bg_r, f32 bg_g, f32 bg_b, bool img) {
    D3D11_MAPPED_SUBRESOURCE mapped;
    if gpu_ctx.lpVtbl.Map(gpu_ctx, gpu_cbuf, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped) < 0 { return; }
    f32* c = cast(f32*, mapped.pData);
    c[0] = cast(f32, s.w);
    c[1] = cast(f32, s.h);
    c[2] = 0.0f;
    c[3] = cast(f32, g_caption_h);   // self-drawn caption shift
    c[4] = bg_r;
    c[5] = bg_g;
    c[6] = bg_b;
    c[7] = 0.0f;
    if img { c[7] = 1.0f; }
    gpu_ctx.lpVtbl.Unmap(gpu_ctx, gpu_cbuf, 0);
}

void gpu_frame_end(f32 bg_r, f32 bg_g, f32 bg_b) {
    GpuSurf* s = &gpu_surf[gpu_bound];
    f32[4] clear = { bg_r, bg_g, bg_b, 1.0f };
    gpu_ctx.lpVtbl.ClearRenderTargetView(gpu_ctx, s.rtv, &clear[0]);

    D3D11_MAPPED_SUBRESOURCE mapped;
    gpu_cbuf_set(s, bg_r, bg_g, bg_b, false);
    if draw_nverts > 0 {
        if gpu_ctx.lpVtbl.Map(gpu_ctx, gpu_vbuf, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped) >= 0 {
            memcpy(mapped.pData, draw_verts, draw_nverts * sizeof(DrawVtx));
            gpu_ctx.lpVtbl.Unmap(gpu_ctx, gpu_vbuf, 0);
        }
    }

    D3D11_VIEWPORT vp;
    vp.Width = cast(f32, s.w);
    vp.Height = cast(f32, s.h);
    vp.MaxDepth = 1.0f;
    gpu_ctx.lpVtbl.RSSetViewports(gpu_ctx, 1, &vp);
    gpu_ctx.lpVtbl.RSSetState(gpu_ctx, gpu_raster);
    gpu_ctx.lpVtbl.OMSetRenderTargets(gpu_ctx, 1, &s.rtv, null);
    f32[4] bf = { 1.0f, 1.0f, 1.0f, 1.0f };
    gpu_ctx.lpVtbl.OMSetBlendState(gpu_ctx, gpu_blend, &bf[0], 0xFFFFFFFF);
    gpu_ctx.lpVtbl.IASetInputLayout(gpu_ctx, gpu_layout);
    gpu_ctx.lpVtbl.IASetPrimitiveTopology(gpu_ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    u32 stride = cast(u32, sizeof(DrawVtx));
    u32 offset = 0;
    gpu_ctx.lpVtbl.IASetVertexBuffers(gpu_ctx, 0, 1, &gpu_vbuf, &stride, &offset);
    gpu_ctx.lpVtbl.VSSetShader(gpu_ctx, gpu_vs, null, 0);
    gpu_ctx.lpVtbl.VSSetConstantBuffers(gpu_ctx, 0, 1, &gpu_cbuf);
    gpu_ctx.lpVtbl.PSSetShader(gpu_ctx, gpu_ps, null, 0);
    // the pixel shader reads the background color out of the same
    // cbuffer, so it must be bound to this stage too; without it that
    // stage reads zeros and text blends against black
    gpu_ctx.lpVtbl.PSSetConstantBuffers(gpu_ctx, 0, 1, &gpu_cbuf);
    // each run with its texture: the atlas, or an image, which the
    // shader draws as it is (the constant buffer's fourth background
    // slot says which)
    bool img_on = false;
    for i32 r = 0; r < draw_nruns; r++ {
        i32 first = draw_run_first[r];
        i32 end = draw_nverts;
        if r + 1 < draw_nruns { end = draw_run_first[r + 1]; }
        if end <= first { continue; }
        i32 t = draw_run_tex[r];
        bool img = t >= 0 && t < GPU_IMAGE_MAX && gpu_images[t].used;
        if t >= 0 && !img { continue; }   // an image freed while its quads were queued
        if img != img_on {
            gpu_cbuf_set(s, bg_r, bg_g, bg_b, img);
            img_on = img;
        }
        if img {
            gpu_ctx.lpVtbl.PSSetShaderResources(gpu_ctx, 0, 1, &gpu_images[t].srv);
            if (draw_run_flags[r] & DRAW_RUN_NEAREST) != 0 {
                gpu_ctx.lpVtbl.PSSetSamplers(gpu_ctx, 0, 1, &gpu_img_blocks);
            } else {
                gpu_ctx.lpVtbl.PSSetSamplers(gpu_ctx, 0, 1, &gpu_img_smooth);
            }
        } else {
            gpu_ctx.lpVtbl.PSSetShaderResources(gpu_ctx, 0, 1, &gpu_atlas_srv);
            gpu_ctx.lpVtbl.PSSetSamplers(gpu_ctx, 0, 1, &gpu_sampler);
        }
        gpu_ctx.lpVtbl.Draw(gpu_ctx, cast(u32, end - first), cast(u32, first));
    }
    if shot_on {
        shot_on = false;
        gpu_do_shot();
    }
    ignore s.sc.lpVtbl.Present(s.sc, 1, 0);
}
