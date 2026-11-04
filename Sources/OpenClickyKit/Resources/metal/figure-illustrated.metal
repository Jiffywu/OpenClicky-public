// OpenClicky figures: the illustrated look and the part-id passes. (Concatenated last; see figure-common.metal.)
//
// Colour is flat two-tone: the part's own colour where the key light reaches, a cooler darker shade where it does
// not, with a narrow soft terminator and a small crisp highlight on glossy parts. A separate pass writes each part's
// id per pixel; the outline pass inks every pixel within the pen width of a change of id, heavier against the
// background (silhouette) than between parts (seams). The same id buffer answers picking.

inline float4 fig_toon_shade(FigVarying in, bool front, constant FigFrame& f, constant FigObject& o, FigDerivs d,
                             thread bool& isCap) {
    float3 V = normalize(f.eye.xyz - in.world);
    float3 base = o.baseColor.rgb;
    float metal = o.surface.y;
    float roughness = o.surface.x;
    float3 coolShade = mix(float3(0.52, 0.56, 0.72), float3(0.38, 0.42, 0.58), metal);
    float3 L = f.keyDir.xyz;
    isCap = false;

    float3 N = o.extra.z > 0.5 ? d.faceNormal : normalize(in.normal);
    if (!front) {
        if (fig_cut_active(o)) {
            isCap = true;
            float3 nc = normalize(o.cut.xyz);
            if (dot(nc, V) < 0.0) nc = -nc;
            float lit = smoothstep(-0.03, 0.05, dot(nc, L));
            float3 capBase = mix(base, float3(1.0), 0.3);
            float3 c = mix(capBase * mix(coolShade, float3(1.0), 0.45), capBase, lit);
            c = mix(c, base * coolShade * 0.8, 0.55 * d.hatch);
            return float4(fig_srgb(c), 1.0);
        }
        N = -N;
    }

    float ndl = dot(N, L);
    float lit = smoothstep(-0.03, 0.05, ndl);
    float3 c = mix(base * coolShade, base, lit);
    c *= mix(0.84, 1.0, smoothstep(-0.85, -0.25, ndl));
    // Metals get a second, lighter band toward the light so they still read as shiny.
    c = mix(c, mix(base, float3(1.0), 0.35), metal * smoothstep(0.55, 0.62, ndl) * 0.6);
    float3 H = normalize(L + V);
    float shininess = mix(260.0, 36.0, roughness);
    float spec = pow(saturate(dot(N, H)), shininess);
    float gloss = (1.0 - roughness) * mix(0.8, 1.0, metal);
    c = mix(c, float3(1.0), smoothstep(0.5, 0.58, spec) * gloss * lit * 0.92);

    float alpha = o.baseColor.a;
    if (o.extra.y > 0.5) {
        float rim = pow(1.0 - saturate(dot(N, V)), 2.0);
        alpha = saturate(alpha + rim * 0.6);
        c = mix(c, float3(1.0), rim * 0.5);
    }
    float glow = o.emissive.a;
    if (glow > 0.0) {
        float3 e = o.emissive.rgb;
        float3 hue = e / max(max(e.r, max(e.g, e.b)), 1e-3);
        c = mix(c, mix(hue, float3(1.0), 0.3 * pow(saturate(dot(N, V)), 2.0)), glow);
        alpha = max(alpha, glow);
    }
    c = mix(c, float3(1.0), 0.28 * o.misc.x);
    return float4(fig_srgb(c) * alpha, alpha);
}

fragment float4 fig_toon_fragment(FigVarying in [[stage_in]], bool front [[front_facing]],
                                  constant FigFrame& f [[buffer(1)]], constant FigObject& o [[buffer(2)]]) {
    FigDerivs d = fig_derivs(in, f, o);
    bool cap = false;
    return fig_toon_shade(in, front, f, o, d, cap);
}

fragment float4 fig_toon_cut_fragment(FigVarying in [[stage_in]], bool front [[front_facing]],
                                      constant FigFrame& f [[buffer(1)]], constant FigObject& o [[buffer(2)]]) {
    FigDerivs d = fig_derivs(in, f, o);
    if (fig_is_cut_away(o, in.world)) discard_fragment();
    bool cap = false;
    return fig_toon_shade(in, front, f, o, d, cap);
}

// ---- part ids ---------------------------------------------------------------------------------------------

/// Each pixel's part id (0 = nothing). The inside of a cut part, seen through the opening, sets the high bit so the
/// pen also outlines the cut face.
fragment uint fig_id_fragment(FigVarying in [[stage_in]], bool front [[front_facing]],
                              constant FigObject& o [[buffer(2)]]) {
    uint id = o.ids.x;
    if (!front && fig_cut_active(o)) id |= 0x80000000u;
    return id;
}

fragment uint fig_id_cut_fragment(FigVarying in [[stage_in]], bool front [[front_facing]],
                                  constant FigObject& o [[buffer(2)]]) {
    if (fig_is_cut_away(o, in.world)) discard_fragment();
    return front ? o.ids.x : (o.ids.x | 0x80000000u);
}

// ---- ink outline ------------------------------------------------------------------------------------------

/// Ink over the shaded image: coverage falls off with the distance to the nearest pixel of another id, within
/// the pen's half width (antialiased over one pixel). Seams between parts use a lighter pen.
fragment float4 fig_outline_fragment(FigFullscreenOut in [[stage_in]], texture2d<uint> ids [[texture(0)]],
                                     constant FigFrame& f [[buffer(1)]]) {
    int2 size = int2(ids.get_width(), ids.get_height());
    int2 p = int2(in.position.xy);
    uint center = ids.read(uint2(p)).r;
    float halfWidth = f.ink.a;
    float seamHalf = halfWidth * 0.55;
    int reach = int(ceil(halfWidth + 1.0));
    float silhouette = 1e4;
    float seam = 1e4;
    for (int y = -reach; y <= reach; y++) {
        for (int x = -reach; x <= reach; x++) {
            if (x == 0 && y == 0) continue;
            int2 q = p + int2(x, y);
            uint other = (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) ? 0u : ids.read(uint2(q)).r;
            if (other == center) continue;
            float distance = length(float2(x, y)) - 0.5;
            if (other == 0u || center == 0u) silhouette = min(silhouette, distance);
            else seam = min(seam, distance);
        }
    }
    float ink = saturate(halfWidth + 0.5 - silhouette);
    float seamInk = saturate(seamHalf + 0.5 - seam) * f.look.x;
    float alpha = max(ink, seamInk);
    return float4(f.ink.rgb * alpha, alpha);
}
