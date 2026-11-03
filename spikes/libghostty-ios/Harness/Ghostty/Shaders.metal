#include <metal_stdlib>
using namespace metal;

// Cell-quad renderer for the libghostty-vt spike: one instanced draw for
// backgrounds/decorations, one for glyphs sampled from a CoreText atlas.

struct Uniforms {
    float2 viewport;   // drawable size, px
    float2 cell;       // on-screen cell size, px
    float2 origin;     // grid origin, px (y carries the smooth-scroll shift)
    float2 atlasSize;  // atlas texture size, px
    float glyphScale;  // on-screen px per atlas px (below 1 for a scaled fixed grid)
    float pad;
};

struct BgInstance {
    float4 rect;  // x, y, width, height in cells
    uint color;   // 0xRRGGBBAA
    uint p0, p1, p2;
};

struct GlyphInstance {
    float2 cell;  // column, viewport row
    float2 pad;
    float4 uv;    // atlas x, y, width, height in px
    uint color;   // 0xRRGGBBAA
    uint flags;   // 1: color glyph (emoji)
    uint p0, p1;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
    float4 color;
    uint flags [[flat]];
};

static float4 unpack(uint c) {
    return float4((c >> 24) & 255, (c >> 16) & 255, (c >> 8) & 255, c & 255) / 255.0;
}

static float4 ndc(float2 px, float2 viewport) {
    return float4(px.x / viewport.x * 2 - 1, 1 - px.y / viewport.y * 2, 0, 1);
}

vertex VOut bg_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      constant Uniforms &u [[buffer(0)]],
                      const device BgInstance *inst [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    BgInstance b = inst[iid];
    VOut o;
    o.pos = ndc(u.origin + (b.rect.xy + corner * b.rect.zw) * u.cell, u.viewport);
    o.uv = 0;
    o.color = unpack(b.color);
    o.flags = 0;
    return o;
}

fragment float4 bg_fragment(VOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

vertex VOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                         constant Uniforms &u [[buffer(0)]],
                         const device GlyphInstance *inst [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    GlyphInstance g = inst[iid];
    VOut o;
    o.pos = ndc(u.origin + g.cell * u.cell + corner * g.uv.zw * u.glyphScale, u.viewport);
    o.uv = (g.uv.xy + corner * g.uv.zw) / u.atlasSize;
    o.color = unpack(g.color);
    o.flags = g.flags;
    return o;
}

fragment float4 glyph_fragment(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 t = atlas.sample(s, in.uv);
    if (in.flags & 1) {
        return t * in.color.a;
    }
    float a = t.a * in.color.a;
    return float4(in.color.rgb * a, a);
}
