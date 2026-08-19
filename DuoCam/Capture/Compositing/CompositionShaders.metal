#include <metal_stdlib>
using namespace metal;

// Layout modes. Kept as an int rather than separate pipelines because Doc 3
// Phase 4 task 13 requires layout to change *during* recording with no dropped
// frames: switching a uniform costs nothing, rebuilding a pipeline stalls.
constant int kModePiP = 0;
constant int kModeSplitHorizontal = 1;
constant int kModeSplitDiagonal = 2;

// Pixel formats a stream can arrive in. The real capture path delivers
// 420YpCbCr8BiPlanarFullRange (Doc 3 Phase 2 task 1); the simulated path
// delivers BGRA. Supporting both is what lets the whole compositing and
// recording pipeline be exercised in the simulator.
constant int kFormatBiplanar = 0;
constant int kFormatBGRA = 1;

struct CompositionUniforms {
    // Output-UV → texture-UV, encoding rotation, mirroring and aspect-fill crop.
    float3x3 primaryTransform;
    float3x3 secondaryTransform;
    // x, y, width, height in output-normalised coordinates.
    float4 secondaryRect;
    float4 strokeColor;
    float cornerRadius;   // in output-normalised units of the shorter axis
    float strokeWidth;
    float splitRatio;
    float diagonalAngle;  // radians
    int mode;
    int isCircular;
    int hasSecondary;
    int primaryFormat;
    int secondaryFormat;
    // width / height of the composited output. Shape maths runs in isotropic
    // "x-units" derived from this: in raw normalised UV a circle renders as an
    // ellipse and a rounded corner as an oval, because one UV unit is 1080px
    // across and 1920px down.
    float outputAspect;
    int _pad0;
    int _pad1;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// A full-screen triangle rather than a quad: one fewer vertex, no diagonal
// seam, and no vertex buffer to bind.
vertex VertexOut compositeVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -3.0),
        float2(-1.0,  1.0),
        float2( 3.0,  1.0)
    };
    const float2 uvs[3] = {
        float2(0.0, 2.0),
        float2(0.0, 0.0),
        float2(2.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

// MARK: - Sampling

// BT.709 full-range YCbCr → RGB.
static float3 ycbcrToRGB(float luma, float2 chroma) {
    float y = luma;
    float cb = chroma.x - 0.5;
    float cr = chroma.y - 0.5;
    return float3(
        y + 1.5748 * cr,
        y - 0.1873 * cb - 0.4681 * cr,
        y + 1.8556 * cb
    );
}

static float3 sampleStream(texture2d<float> lumaOrBGRA,
                           texture2d<float> chroma,
                           sampler s,
                           float2 uv,
                           int format) {
    if (format == kFormatBGRA) {
        return lumaOrBGRA.sample(s, uv).rgb;
    }
    float luma = lumaOrBGRA.sample(s, uv).r;
    float2 cbcr = chroma.sample(s, uv).rg;
    return ycbcrToRGB(luma, cbcr);
}

static float2 transformUV(float3x3 m, float2 uv) {
    float3 t = m * float3(uv, 1.0);
    return t.xy;
}

// MARK: - Shape

// Signed distance to a rounded rectangle, in the rect's own space.
// Negative inside. Used for both the mask and the stroke, so the two can never
// disagree about where the edge is.
static float roundedRectDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// Approximate signed distance to an axis-aligned ellipse (Quilez). Negative
// inside, and — unlike the naive `length(p / r) - 1` — scaled in real distance
// units, which is what the antialiasing width and the inset stroke both depend
// on: a scaled field would make the border thicken at the flat ends of a
// squashed overlay and thin at the sharp ones.
//
// Degenerates to `length(p) - r` when the two radii agree, so a circular
// overlay left at equal width and height is still exactly a circle.
static float ellipseDistance(float2 p, float2 radii) {
    float2 r = max(radii, 1e-5);
    float k0 = length(p / r);
    if (k0 < 1e-5) { return -min(r.x, r.y); }
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / k1;
}

// MARK: - Fragment

fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                  texture2d<float> primaryLuma  [[texture(0)]],
                                  texture2d<float> primaryChroma [[texture(1)]],
                                  texture2d<float> secondaryLuma [[texture(2)]],
                                  texture2d<float> secondaryChroma [[texture(3)]],
                                  constant CompositionUniforms &u [[buffer(0)]]) {
    constexpr sampler linearSampler(filter::linear,
                                    address::clamp_to_edge,
                                    coord::normalized);

    float2 uv = in.uv;

    float3 primary = sampleStream(primaryLuma, primaryChroma, linearSampler,
                                  transformUV(u.primaryTransform, uv),
                                  u.primaryFormat);

    if (u.hasSecondary == 0) {
        return float4(primary, 1.0);
    }

    float3 secondary = sampleStream(secondaryLuma, secondaryChroma, linearSampler,
                                    transformUV(u.secondaryTransform, uv),
                                    u.secondaryFormat);

    if (u.mode == kModeSplitHorizontal) {
        // A hard edge would alias badly on a moving seam; one pixel of feather
        // costs nothing and removes the crawl.
        float feather = 0.001;
        float t = smoothstep(u.splitRatio - feather, u.splitRatio + feather, uv.y);
        return float4(mix(primary, secondary, t), 1.0);
    }

    if (u.mode == kModeSplitDiagonal) {
        // Signed distance to a line through the centre at `diagonalAngle`.
        float2 p = uv - float2(0.5, 0.5);
        float2 normal = float2(-sin(u.diagonalAngle), cos(u.diagonalAngle));
        float d = dot(p, normal);
        float feather = 0.002;
        float t = smoothstep(-feather, feather, d);
        return float4(mix(primary, secondary, t), 1.0);
    }

    // PiP: the secondary occupies `secondaryRect`, clipped to a rounded
    // rectangle or a circle, with a stroke on the boundary. All of it is
    // measured in isotropic x-units so corners stay circular.
    float invAspect = 1.0 / u.outputAspect;
    float2 q = float2(uv.x, uv.y * invAspect);
    float2 rectCentre = float2(u.secondaryRect.x + u.secondaryRect.z * 0.5,
                               (u.secondaryRect.y + u.secondaryRect.w * 0.5) * invAspect);
    float2 halfSize = float2(u.secondaryRect.z * 0.5, u.secondaryRect.w * 0.5 * invAspect);
    float2 p = q - rectCentre;

    float distance;
    if (u.isCircular != 0) {
        distance = ellipseDistance(p, halfSize);
    } else {
        distance = roundedRectDistance(p, halfSize, u.cornerRadius);
    }

    // Feather scaled to a pixel so the edge stays crisp at every output size.
    // The stroke is the band just *inside* the boundary: -strokeWidth < d < 0.
    // Drawing it outside would let it overlap whatever the overlay is sitting
    // on and make the overlay read as larger than its own frame.
    float aa = fwidth(distance) * 0.5;
    float inside = 1.0 - smoothstep(-aa, aa, distance);
    float insideInner = 1.0 - smoothstep(-aa, aa, distance + u.strokeWidth);
    float onStroke = inside - insideInner;

    float3 composed = mix(primary, secondary, inside);
    composed = mix(composed, u.strokeColor.rgb, clamp(onStroke, 0.0, 1.0) * u.strokeColor.a);

    return float4(composed, 1.0);
}
