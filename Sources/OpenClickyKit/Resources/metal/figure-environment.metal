// OpenClicky figures: the procedural photo studio the studio look reflects, baked once into cube maps.
// (Concatenated after figure-common.metal; see the note there.)
//
// The studio is a dim, neutral room (darker floor, lighter ceiling) lit by four softboxes: a large warm key up and
// to the left in front, a tall strip on the right, a square panel overhead and a cool strip behind, plus a broad
// dim panel behind the camera so flat metal faces turned to the viewer have something to reflect. Directions are
// in the studio frame, which turns with the camera so the lighting stays put as the figure spins.

struct FigEnvParams {
    float4 room;   // x room level, y key softbox, z right strip, w overhead panel
    float4 misc;   // x back strip, y roughness (prefilter), z sample count, w source mip count
    float4 fill;   // x broad panel behind the camera, y bounce card low in front
};

/// Direction through texel `uv` (0..1) of cube face `face` (+X, -X, +Y, -Y, +Z, -Z).
inline float3 fig_cube_direction(uint face, float2 uv) {
    float2 c = uv * 2.0 - 1.0;
    switch (face) {
        case 0: return float3(1.0, -c.y, -c.x);
        case 1: return float3(-1.0, -c.y, c.x);
        case 2: return float3(c.x, 1.0, c.y);
        case 3: return float3(c.x, -1.0, -c.y);
        case 4: return float3(c.x, -c.y, 1.0);
        default: return float3(-c.x, -c.y, -1.0);
    }
}

/// A rectangular softbox seen from the centre: brightest in the middle, soft at the edges.
inline float fig_softbox(float3 d, float3 center, float2 halfSize) {
    float facing = dot(d, center);
    if (facing <= 0.05) return 0.0;
    float3 up = abs(center.y) > 0.95 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
    float3 u = normalize(cross(up, center));
    float3 v = cross(center, u);
    float2 q = float2(dot(d, u), dot(d, v)) / facing;
    float2 e = abs(q) / halfSize;
    float edge = max(e.x, e.y);
    float body = 1.0 - smoothstep(0.82, 1.0, edge);
    float falloff = 1.0 - 0.25 * dot(q / halfSize, q / halfSize) * 0.25;
    return body * max(falloff, 0.6);
}

inline float3 fig_studio_radiance(float3 d, constant FigEnvParams& p) {
    float y = d.y;
    float3 floorColor = float3(0.045, 0.045, 0.05);
    float3 wall = float3(0.19, 0.195, 0.205);
    float3 ceiling = float3(0.33, 0.33, 0.34);
    float3 c = y < 0.0 ? mix(wall, floorColor, smoothstep(0.0, 0.45, -y)) : mix(wall, ceiling, smoothstep(0.05, 0.85, y));
    // A faint horizon band gives chrome something to draw across.
    c += float3(0.06) * exp(-abs(y + 0.02) * 22.0);
    c *= p.room.x;
    c += p.room.y * float3(1.0, 0.95, 0.88) * fig_softbox(d, normalize(float3(-0.62, 0.55, 0.56)), float2(0.42, 0.34));
    c += p.room.z * float3(0.94, 0.97, 1.0) * fig_softbox(d, normalize(float3(0.9, 0.12, 0.2)), float2(0.07, 0.55));
    c += p.room.w * float3(1.0, 1.0, 1.0) * fig_softbox(d, float3(0.0, 1.0, 0.0), float2(0.38, 0.38));
    c += p.misc.x * float3(0.78, 0.87, 1.0) * fig_softbox(d, normalize(float3(-0.25, 0.3, -0.92)), float2(0.07, 0.48));
    c += p.fill.x * float3(1.0, 0.99, 0.97) * fig_softbox(d, normalize(float3(0.15, 0.2, 1.0)), float2(1.1, 0.55));
    // A white card on the floor in front of the object, brightest near the horizon: faces turned toward the camera
    // reflect a gradient from it instead of the dark floor, which is what makes flat metal read as metal.
    float card = fig_softbox(d, normalize(float3(0.0, -0.42, 1.0)), float2(1.4, 0.5));
    c += p.fill.y * float3(0.98, 0.97, 0.95) * card * smoothstep(-0.75, -0.05, y);
    return c;
}

kernel void fig_env_bake(texturecube<float, access::write> out [[texture(0)]],
                         constant FigEnvParams& p [[buffer(0)]],
                         uint3 gid [[thread_position_in_grid]]) {
    uint size = out.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6) return;
    float2 uv = (float2(gid.xy) + 0.5) / float(size);
    float3 d = normalize(fig_cube_direction(gid.z, uv));
    out.write(float4(fig_studio_radiance(d, p), 1.0), gid.xy, gid.z);
}

inline float2 fig_hammersley(uint i, uint n) {
    return float2(float(i) / float(n), float(reverse_bits(i)) * 2.3283064365386963e-10);
}

inline float3 fig_tangent_to_world(float3 h, float3 n) {
    float3 up = abs(n.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 t = normalize(cross(up, n));
    float3 b = cross(n, t);
    return normalize(t * h.x + b * h.y + n * h.z);
}

/// Pre-blur the studio for one roughness level (split-sum, view = normal), importance-sampling the GGX lobe and
/// reading blurrier source mips for wide samples so bright softboxes do not sparkle.
kernel void fig_env_prefilter(texturecube<float> source [[texture(0)]],
                              texturecube<float, access::write> out [[texture(1)]],
                              sampler linearSampler [[sampler(0)]],
                              constant FigEnvParams& p [[buffer(0)]],
                              uint3 gid [[thread_position_in_grid]]) {
    uint size = out.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6) return;
    float3 n = normalize(fig_cube_direction(gid.z, (float2(gid.xy) + 0.5) / float(size)));
    float roughness = p.misc.y;
    if (roughness < 0.02) {
        out.write(float4(source.sample(linearSampler, n, level(0.0)).rgb, 1.0), gid.xy, gid.z);
        return;
    }
    float a = roughness * roughness;
    uint count = uint(p.misc.z);
    float sourceSize = float(source.get_width());
    float texelSolidAngle = 4.0 * kFigPi / (6.0 * sourceSize * sourceSize);
    float3 sum = float3(0.0);
    float weight = 0.0;
    for (uint i = 0; i < count; i++) {
        float2 xi = fig_hammersley(i, count);
        float phi = 2.0 * kFigPi * xi.x;
        float cosTheta = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
        float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
        float3 h = fig_tangent_to_world(float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta), n);
        float3 l = normalize(2.0 * dot(n, h) * h - n);
        float nl = dot(n, l);
        if (nl <= 0.0) continue;
        float nh = saturate(dot(n, h));
        float denom = nh * nh * (a * a - 1.0) + 1.0;
        float D = a * a / (kFigPi * denom * denom);
        float pdf = D * 0.25 + 1e-4;
        float sampleSolidAngle = 1.0 / (float(count) * pdf);
        float mip = clamp(0.5 * log2(sampleSolidAngle / texelSolidAngle) + 1.0, 0.0, p.misc.w - 1.0);
        sum += source.sample(linearSampler, l, level(mip)).rgb * nl;
        weight += nl;
    }
    out.write(float4(sum / max(weight, 1e-4), 1.0), gid.xy, gid.z);
}

/// Diffuse light from every direction: the cosine-weighted mean of the studio over a hemisphere. Stored as mean
/// radiance, so shading multiplies it by the diffuse colour directly.
kernel void fig_env_irradiance(texturecube<float> source [[texture(0)]],
                               texturecube<float, access::write> out [[texture(1)]],
                               sampler linearSampler [[sampler(0)]],
                               constant FigEnvParams& p [[buffer(0)]],
                               uint3 gid [[thread_position_in_grid]]) {
    uint size = out.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6) return;
    float3 n = normalize(fig_cube_direction(gid.z, (float2(gid.xy) + 0.5) / float(size)));
    const uint count = 384;
    float mip = max(p.misc.w - 4.0, 0.0);
    float3 sum = float3(0.0);
    for (uint i = 0; i < count; i++) {
        float2 xi = fig_hammersley(i, count);
        float phi = 2.0 * kFigPi * xi.x;
        float cosTheta = sqrt(1.0 - xi.y);
        float sinTheta = sqrt(xi.y);
        float3 l = fig_tangent_to_world(float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta), n);
        sum += source.sample(linearSampler, l, level(mip)).rgb;
    }
    out.write(float4(sum / float(count), 1.0), gid.xy, gid.z);
}
