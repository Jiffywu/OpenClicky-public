// OpenClicky figures: declarations shared by both looks.
//
// FigureRenderer concatenates figure-common, figure-environment, figure-studio and figure-illustrated (in that
// order) and compiles them at run time with MTLDevice.makeLibrary(source:). The structs below must match the Swift
// mirrors in FigureRenderer.swift field for field.
#include <metal_stdlib>
using namespace metal;

constant float kFigPi = 3.14159265358979;

struct FigVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

struct FigFrame {
    float4x4 viewProj;
    float4x4 view;
    float4x4 lightViewProj;
    float4 eye;         // xyz camera position
    float4 keyDir;      // xyz toward the key light (world), w unused
    float4 keyColor;    // rgb key irradiance
    float4 rimDir;      // xyz toward the rim light (world)
    float4 rimColor;    // rgb rim irradiance
    float4 env;         // x cos(yaw), y sin(yaw): world -> studio turn; z environment strength; w exposure
    float4 shadow;      // x shadow-map texel size (uv), y depth bias, z normal offset (world), w penumbra scale
    float4 ground;      // x height, y centre x, z centre z, w half size
    float4 groundTint;  // rgb shadow colour (linear), a opacity
    float4 ao;          // x radius (world), y strength, z enabled
    float4 viewport;    // x width, y height (pixels), z 1/width, w 1/height
    float4 ink;         // rgb ink (sRGB), a outline half width (pixels)
    float4 proj;        // x P[0][0], y P[1][1], z near, w far
    float4 hatch;       // x line spacing (world), y line width (fraction of spacing), z specular mip count - 1
    float4 look;        // x seam strength, y saturation boost
};

struct FigObject {
    float4x4 model;
    float4 normal0;
    float4 normal1;
    float4 normal2;
    float4 baseColor;   // linear rgb, a opacity
    float4 emissive;    // linear rgb, a glow 0..1
    float4 surface;     // x roughness, y metalness, z clearcoat, w clearcoat roughness
    float4 extra;       // x sheen, y glass, z flat shading, w double sided
    float4 cut;         // xyz world normal toward the removed half, w offset; off when |xyz| < 0.5
    float4 misc;        // x highlight 0..1
    uint4 ids;          // x picking id
};

struct FigVarying {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
    float viewDepth;
};

struct FigFullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FigVarying fig_vertex(FigVertexIn in [[stage_in]],
                             constant FigFrame& frame [[buffer(1)]],
                             constant FigObject& obj [[buffer(2)]]) {
    float4 world = obj.model * float4(in.position, 1.0);
    float3x3 normalMatrix = float3x3(obj.normal0.xyz, obj.normal1.xyz, obj.normal2.xyz);
    FigVarying out;
    out.position = frame.viewProj * world;
    out.world = world.xyz;
    out.normal = normalMatrix * in.normal;
    out.uv = in.uv;
    out.viewDepth = -(frame.view * world).z;
    return out;
}

/// One triangle covering the screen.
vertex FigFullscreenOut fig_fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FigFullscreenOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// ---- helpers ----------------------------------------------------------------------------------------------

inline float3 fig_srgb(float3 c) {
    c = saturate(c);
    float3 low = c * 12.92;
    float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

inline float fig_hash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

/// Point i of n on a unit disk, spread along a golden-angle spiral and turned by `angle`.
inline float2 fig_spiral(int i, int n, float angle) {
    float r = sqrt((float(i) + 0.5) / float(n));
    float a = float(i) * 2.39996323 + angle;
    return float2(cos(a), sin(a)) * r;
}

inline bool fig_cut_active(constant FigObject& o) { return dot(o.cut.xyz, o.cut.xyz) > 0.25; }

inline bool fig_is_cut_away(constant FigObject& o, float3 world) {
    return fig_cut_active(o) && dot(world, o.cut.xyz) > o.cut.w;
}

/// Where the eye ray through `world` crosses the cut plane (the visible cut face lies there).
inline float3 fig_cut_point(constant FigObject& o, float3 eye, float3 world) {
    float3 dir = normalize(world - eye);
    float denom = dot(o.cut.xyz, dir);
    float t = abs(denom) > 1e-5 ? (o.cut.w - dot(o.cut.xyz, eye)) / denom : 0.0;
    return eye + dir * max(t, 0.0);
}

/// Cross-hatching on a cut face: two diagonal families of lines in the cut plane, antialiased by their footprint.
inline float fig_hatch(constant FigObject& o, float3 p, float spacing, float width) {
    float3 n = normalize(o.cut.xyz + float3(1e-6));
    float3 helper = abs(n.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 u = normalize(cross(helper, n));
    float3 v = cross(n, u);
    float a = dot(p, u + v) / spacing;
    float b = dot(p, u - v) / spacing;
    float da = abs(fract(a + 0.5) - 0.5);
    float db = abs(fract(b + 0.5) - 0.5);
    float wa = max(fwidth(a), 1e-4);
    float wb = max(fwidth(b), 1e-4);
    float half_w = width * 0.5;
    float la = 1.0 - smoothstep(half_w - wa, half_w + wa, da);
    float lb = 1.0 - smoothstep(half_w - wb, half_w + wb, db);
    // Fade the pattern out where lines would be thinner than a pixel apart.
    float fade = 1.0 - smoothstep(0.25, 0.5, max(wa, wb));
    return max(la, lb) * fade;
}

/// Screen-space quantities that need derivatives; computed before any discard, in uniform control flow.
struct FigDerivs {
    float hatch;
    float3 faceNormal;
    float normalVariance;
    float3 capPoint;
};

inline FigDerivs fig_derivs(FigVarying in, constant FigFrame& f, constant FigObject& o) {
    FigDerivs d;
    d.capPoint = fig_cut_point(o, f.eye.xyz, in.world);
    d.hatch = fig_hatch(o, d.capPoint, f.hatch.x, f.hatch.y);
    float3 face = cross(dfdx(in.world), dfdy(in.world));
    d.faceNormal = length(face) > 1e-12 ? normalize(face) : float3(0.0, 1.0, 0.0);
    if (dot(d.faceNormal, f.eye.xyz - in.world) < 0.0) d.faceNormal = -d.faceNormal;
    float3 dn = fwidth(normalize(in.normal));
    d.normalVariance = min(dot(dn, dn), 0.18);
    return d;
}

/// A soft shoulder that keeps hue: the brightest channel rolls off toward 1 and over-bright colour drifts to white.
inline float3 fig_tonemap(float3 c, float saturationBoost) {
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = max(mix(float3(luma), c, saturationBoost), 0.0);
    const float start = 0.72;
    float peak = max(c.r, max(c.g, c.b));
    if (peak <= start) return c;
    float span = 1.0 - start;
    float rolled = 1.0 - span * span / (peak + span - start);
    c *= rolled / peak;
    float whiten = 1.0 - 1.0 / (0.12 * (peak - rolled) + 1.0);
    return mix(c, float3(rolled), whiten);
}

// ---- shadow map -------------------------------------------------------------------------------------------

struct FigShadowVarying {
    float4 position [[position]];
    float3 world;
};

vertex FigShadowVarying fig_shadow_vertex(FigVertexIn in [[stage_in]],
                                          constant FigFrame& frame [[buffer(1)]],
                                          constant FigObject& obj [[buffer(2)]]) {
    float4 world = obj.model * float4(in.position, 1.0);
    FigShadowVarying out;
    out.position = frame.lightViewProj * world;
    out.world = world.xyz;
    return out;
}

/// Cut parts cast shadows only from the half that remains.
fragment void fig_shadow_fragment(FigShadowVarying in [[stage_in]], constant FigObject& obj [[buffer(2)]]) {
    if (fig_is_cut_away(obj, in.world)) discard_fragment();
}

/// How much of the key light reaches `world`: a blocker search sets the penumbra (wider the further the occluder
/// is from the receiver), then a rotated spiral of comparison taps averages it.
inline float fig_shadow_visibility(depth2d<float> map, sampler compareSampler, sampler pointSampler,
                                   constant FigFrame& f, float3 world, float3 n, float2 pixel, float softScale) {
    float NoL = dot(n, f.keyDir.xyz);
    float3 p = world + n * f.shadow.z * (1.0 + 2.0 * (1.0 - saturate(NoL)));
    float4 lc = f.lightViewProj * float4(p, 1.0);
    float3 q = lc.xyz / lc.w;
    float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || q.z >= 1.0) return 1.0;
    float z = q.z - f.shadow.y;
    float angle = fig_hash(pixel) * 6.2831853;
    float texel = f.shadow.x;
    float blockerSum = 0.0;
    float blockers = 0.0;
    for (int i = 0; i < 10; i++) {
        float d = map.sample(pointSampler, uv + fig_spiral(i, 10, angle) * texel * 12.0);
        if (d < z) { blockerSum += d; blockers += 1.0; }
    }
    if (blockers < 0.5) return 1.0;
    float gap = z - blockerSum / blockers;
    float radius = clamp(gap * f.shadow.w * softScale, 1.0, 18.0) * texel;
    float lit = 0.0;
    for (int i = 0; i < 16; i++) {
        lit += map.sample_compare(compareSampler, uv + fig_spiral(i, 16, angle) * radius, z);
    }
    return lit / 16.0;
}
