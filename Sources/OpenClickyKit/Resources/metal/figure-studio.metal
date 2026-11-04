// OpenClicky figures: the studio look. (Concatenated after figure-environment.metal; see figure-common.metal.)
//
// Physically based shading (GGX specular with height-correlated visibility, Lambert diffuse), lit by a shadowing key
// light, an unshadowed rim light and the baked studio (diffuse irradiance + pre-blurred reflections), darkened by
// screen-space ambient occlusion. Extras: clear coat, sheen, glass, glow, and hatched cut-away faces. A transparent
// ground plane shows only the object's soft shadow.

inline float3 fig_to_studio(constant FigFrame& f, float3 d) {
    float c = f.env.x, s = f.env.y;
    return float3(d.x * c - d.z * s, d.y, d.x * s + d.z * c);
}

inline float fig_ggx(float nh, float a) {
    float a2 = a * a;
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (kFigPi * d * d);
}

inline float fig_visibility(float nv, float nl, float a) {
    float a2 = a * a;
    float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-5);
}

inline float3 fig_fresnel(float3 f0, float vh) {
    return f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
}

/// Analytic stand-in for the split-sum environment BRDF table (scale and bias on F0 by roughness and view angle).
inline float3 fig_env_brdf(float3 f0, float nv, float roughness) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
    float2 ab = float2(-1.04, 1.04) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

inline float4 fig_studio_shade(FigVarying in, bool front, constant FigFrame& f, constant FigObject& o, FigDerivs d,
                               depth2d<float> shadowMap, texturecube<float> envSpecular, texturecube<float> envDiffuse,
                               texture2d<float> occlusion, sampler compareSampler, sampler pointSampler,
                               sampler linearSampler, thread bool& isCap) {
    float3 V = normalize(f.eye.xyz - in.world);
    float3 base = o.baseColor.rgb;
    float opacity = o.baseColor.a;
    bool glass = o.extra.y > 0.5;
    float2 screen = in.position.xy * f.viewport.zw;
    float ao = (f.ao.z > 0.5 && !glass) ? occlusion.sample(linearSampler, screen).r : 1.0;
    float maxMip = f.hatch.z;
    float exposure = f.env.w;
    isCap = false;

    float3 N = o.extra.z > 0.5 ? d.faceNormal : normalize(in.normal);
    if (!front) {
        if (fig_cut_active(o)) {
            // The inside seen through the opening is drawn as the solid cut face, lighter, with hatching.
            isCap = true;
            float3 nc = normalize(o.cut.xyz);
            if (dot(nc, V) < 0.0) nc = -nc;
            float3 capBase = mix(base, float3(1.0), 0.22) * (1.0 - 0.55 * o.surface.y) + base * 0.55 * o.surface.y;
            float key = saturate(dot(nc, f.keyDir.xyz));
            float3 ambient = envDiffuse.sample(linearSampler, fig_to_studio(f, nc)).rgb * f.env.z;
            float3 c = capBase * (key * f.keyColor.rgb / kFigPi + ambient * 1.4 + 0.12);
            c *= mix(0.55, 1.0, ao);
            c *= 1.0 - 0.45 * d.hatch;
            float3 mapped = fig_tonemap(c * exposure, f.look.y);
            return float4(fig_srgb(mapped), 1.0);
        }
        N = -N;
    }

    float nv = max(dot(N, V), 1e-4);
    float roughness = clamp(sqrt(o.surface.x * o.surface.x + d.normalVariance), 0.045, 1.0);
    float a = roughness * roughness;
    float metal = o.surface.y;
    float3 f0 = mix(float3(0.04), base, metal);
    float3 diffuseColor = base * (1.0 - metal);

    // Key light, softened by the shadow map; in shadow it dims rather than going black.
    float3 L = f.keyDir.xyz;
    float shadow = glass ? 1.0 : fig_shadow_visibility(shadowMap, compareSampler, pointSampler, f, in.world, N, in.position.xy, 1.0);
    float3 H = normalize(L + V);
    float nl = saturate(dot(N, L));
    float nh = saturate(dot(N, H));
    float vh = saturate(dot(V, H));
    float3 F = fig_fresnel(f0, vh);
    float3 spec = fig_ggx(nh, a) * fig_visibility(nv, nl, a) * F;
    float3 diffuse = diffuseColor * (1.0 - F) / kFigPi;
    float keyAmount = mix(0.18, 1.0, shadow) * mix(1.0, ao, 0.35);
    float3 color = (diffuse + spec) * f.keyColor.rgb * nl * keyAmount;

    // Rim light from behind: no shadow, just an edge.
    float3 R = f.rimDir.xyz;
    float3 Hr = normalize(R + V);
    float nlr = saturate(dot(N, R));
    float3 Fr = fig_fresnel(f0, saturate(dot(V, Hr)));
    color += (diffuseColor * (1.0 - Fr) / kFigPi + fig_ggx(saturate(dot(N, Hr)), a) * fig_visibility(nv, nlr, a) * Fr) * f.rimColor.rgb * nlr;

    // The studio itself.
    float3 Ns = fig_to_studio(f, N);
    float3 Rs = fig_to_studio(f, reflect(-V, N));
    float3 irradiance = envDiffuse.sample(linearSampler, Ns).rgb;
    float3 prefiltered = envSpecular.sample(linearSampler, Rs, level(roughness * maxMip)).rgb;
    float3 envF = fig_env_brdf(f0, nv, roughness);
    float fill = ao * mix(0.65, 1.0, shadow);
    color += (diffuseColor * irradiance * (1.0 - envF) + prefiltered * envF) * f.env.z * fill;

    // Sheen: a soft bright rim on rubber, cloth and matte paint.
    float sheen = o.extra.x;
    if (sheen > 0.0) {
        color += sheen * pow(1.0 - nv, 3.0) * mix(base, float3(1.0), 0.45) * irradiance * f.env.z * 2.2 * ao;
    }

    // Clear coat: a thin glossy layer over the base.
    float coat = o.surface.z;
    if (coat > 0.0) {
        float coatRough = clamp(o.surface.w, 0.03, 1.0);
        float ac = coatRough * coatRough;
        float coatF = 0.04 + 0.96 * pow(1.0 - vh, 5.0);
        float coatView = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
        float3 coatSpec = fig_ggx(nh, ac) * fig_visibility(nv, nl, ac) * coatF * f.keyColor.rgb * nl * keyAmount;
        float3 coatEnv = envSpecular.sample(linearSampler, Rs, level(coatRough * maxMip)).rgb * coatView * f.env.z * ao;
        color = color * (1.0 - coat * coatView) + coat * (coatSpec + coatEnv);
    }

    float alpha = opacity;
    if (glass) {
        // Thin glass: a faint body tint, reflections that strengthen toward the edges, and highlights that stay solid.
        float fv = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
        float3 reflection = prefiltered * mix(0.04, 1.0, fv) * f.env.z * 1.4;
        float3 keySpec = fig_ggx(nh, max(a, 0.002)) * fig_visibility(nv, nl, max(a, 0.002)) * fv * f.keyColor.rgb * nl;
        color = base * irradiance * f.env.z * 0.35 + reflection + keySpec;
        float highlight = dot(reflection + keySpec, float3(0.3333));
        alpha = saturate(opacity + fv * 0.85 + highlight * 0.35);
    }

    float3 mapped = fig_tonemap(color * exposure, f.look.y);

    // Glow: keep the lamp's own hue (tone mapping would wash it toward white) with a bright core facing the viewer.
    float glow = o.emissive.a;
    if (glow > 0.0) {
        float3 e = o.emissive.rgb;
        float3 hue = e / max(max(e.r, max(e.g, e.b)), 1e-3);
        float3 lamp = mix(hue * 0.92, float3(1.0, 0.97, 0.9), 0.4 * pow(nv, 2.0));
        mapped = mix(mapped, max(mapped, lamp), glow);
        alpha = max(alpha, glow);
    }
    mapped = mix(mapped, float3(1.0), 0.28 * o.misc.x);
    return float4(fig_srgb(mapped) * alpha, alpha);
}

fragment float4 fig_studio_fragment(FigVarying in [[stage_in]], bool front [[front_facing]],
                                    constant FigFrame& f [[buffer(1)]], constant FigObject& o [[buffer(2)]],
                                    depth2d<float> shadowMap [[texture(0)]],
                                    texturecube<float> envSpecular [[texture(1)]],
                                    texturecube<float> envDiffuse [[texture(2)]],
                                    texture2d<float> occlusion [[texture(3)]],
                                    sampler compareSampler [[sampler(0)]], sampler pointSampler [[sampler(1)]],
                                    sampler linearSampler [[sampler(2)]]) {
    FigDerivs d = fig_derivs(in, f, o);
    bool cap = false;
    return fig_studio_shade(in, front, f, o, d, shadowMap, envSpecular, envDiffuse, occlusion, compareSampler,
                            pointSampler, linearSampler, cap);
}

/// For parts with a cut-away: the removed half is discarded, and back faces seen through the opening are drawn as
/// the cut face at their own depth, so only rays that enter solid material behind the plane show it.
fragment float4 fig_studio_cut_fragment(FigVarying in [[stage_in]], bool front [[front_facing]],
                                           constant FigFrame& f [[buffer(1)]], constant FigObject& o [[buffer(2)]],
                                           depth2d<float> shadowMap [[texture(0)]],
                                           texturecube<float> envSpecular [[texture(1)]],
                                           texturecube<float> envDiffuse [[texture(2)]],
                                           texture2d<float> occlusion [[texture(3)]],
                                           sampler compareSampler [[sampler(0)]], sampler pointSampler [[sampler(1)]],
                                           sampler linearSampler [[sampler(2)]]) {
    FigDerivs d = fig_derivs(in, f, o);
    if (fig_is_cut_away(o, in.world)) discard_fragment();
    bool cap = false;
    return fig_studio_shade(in, front, f, o, d, shadowMap, envSpecular, envDiffuse, occlusion, compareSampler,
                            pointSampler, linearSampler, cap);
}

// ---- normals and depth for ambient occlusion --------------------------------------------------------------

fragment float4 fig_normal_depth_fragment(FigVarying in [[stage_in]], bool front [[front_facing]],
                                          constant FigFrame& f [[buffer(1)]], constant FigObject& o [[buffer(2)]]) {
    FigDerivs d = fig_derivs(in, f, o);
    if (fig_is_cut_away(o, in.world)) discard_fragment();
    float3 n = o.extra.z > 0.5 ? d.faceNormal : normalize(in.normal);
    float depth = in.viewDepth;
    if (!front) {
        if (fig_cut_active(o)) {
            n = normalize(o.cut.xyz);
            if (dot(n, f.eye.xyz - in.world) < 0.0) n = -n;
        } else {
            n = -n;
        }
    }
    return float4(normalize((f.view * float4(n, 0.0)).xyz), depth);
}

inline float3 fig_view_position(constant FigFrame& f, float2 pixel, float depth, float2 size) {
    float2 ndc = float2(pixel.x / size.x * 2.0 - 1.0, 1.0 - pixel.y / size.y * 2.0);
    return float3(ndc.x * depth / f.proj.x, ndc.y * depth / f.proj.y, -depth);
}

/// Ambient occlusion: taps on a rotated spiral around each pixel count how much nearby surface rises above it.
fragment float fig_ao_fragment(FigFullscreenOut in [[stage_in]], texture2d<float> normalDepth [[texture(0)]],
                               constant FigFrame& f [[buffer(1)]]) {
    float2 size = float2(normalDepth.get_width(), normalDepth.get_height());
    int2 p = int2(in.position.xy);
    float4 c = normalDepth.read(uint2(p));
    float depth = c.w;
    if (depth <= 0.0) return 1.0;
    float3 P = fig_view_position(f, float2(p) + 0.5, depth, size);
    float3 N = normalize(c.xyz);
    float radius = f.ao.x;
    float reach = clamp(radius * f.proj.y * 0.5 * size.y / depth, 2.0, 40.0);
    float angle = fig_hash(in.position.xy) * 6.2831853;
    float occlusion = 0.0;
    for (int i = 0; i < 12; i++) {
        int2 q = clamp(p + int2(fig_spiral(i, 12, angle) * reach), int2(0), int2(size) - 1);
        float dq = normalDepth.read(uint2(q)).w;
        if (dq <= 0.0) continue;
        float3 v = fig_view_position(f, float2(q) + 0.5, dq, size) - P;
        float vv = dot(v, v);
        float falloff = saturate(1.0 - vv / (radius * radius * 4.0));
        occlusion += max(0.0, dot(v, N) - 0.004 * depth) / (vv + 0.0004 * depth * depth) * falloff * radius;
    }
    return saturate(1.0 - f.ao.y * 0.5 * occlusion / 12.0);
}

/// Smooth the occlusion with neighbours on the same surface only, so it never bleeds across silhouettes.
fragment float fig_ao_blur_fragment(FigFullscreenOut in [[stage_in]], texture2d<float> raw [[texture(0)]],
                                    texture2d<float> normalDepth [[texture(1)]]) {
    int2 size = int2(raw.get_width(), raw.get_height());
    int2 p = int2(in.position.xy);
    float center = normalDepth.read(uint2(p)).w;
    if (center <= 0.0) return 1.0;
    float sum = 0.0;
    float weight = 0.0;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            int2 q = clamp(p + int2(x, y) * 2, int2(0), size - 1);
            float dq = normalDepth.read(uint2(q)).w;
            if (abs(dq - center) > 0.03 * center) continue;
            sum += raw.read(uint2(q)).r;
            weight += 1.0;
        }
    }
    return weight > 0.0 ? sum / weight : 1.0;
}

// ---- shadow-only ground ----------------------------------------------------------------------------------

struct FigGroundVarying {
    float4 position [[position]];
    float3 world;
};

vertex FigGroundVarying fig_ground_vertex(uint vid [[vertex_id]], constant FigFrame& f [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1) * 2.0 - 1.0, float((vid >> 1) & 1) * 2.0 - 1.0);
    float3 world = float3(f.ground.y + corner.x * f.ground.w, f.ground.x, f.ground.z + corner.y * f.ground.w);
    FigGroundVarying out;
    out.position = f.viewProj * float4(world, 1.0);
    out.world = world;
    return out;
}

fragment float4 fig_ground_fragment(FigGroundVarying in [[stage_in]], constant FigFrame& f [[buffer(1)]],
                                    depth2d<float> shadowMap [[texture(0)]],
                                    sampler compareSampler [[sampler(0)]], sampler pointSampler [[sampler(1)]]) {
    float visibility = fig_shadow_visibility(shadowMap, compareSampler, pointSampler, f, in.world, float3(0.0, 1.0, 0.0),
                                             in.position.xy, 1.8);
    float r = length(in.world.xz - float2(f.ground.y, f.ground.z)) / f.ground.w;
    float fade = 1.0 - smoothstep(0.45, 1.0, r);
    float alpha = (1.0 - visibility) * fade * f.groundTint.a;
    return float4(fig_srgb(f.groundTint.rgb) * alpha, alpha);
}
