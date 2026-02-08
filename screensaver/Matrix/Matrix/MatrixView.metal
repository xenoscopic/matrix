#include <metal_stdlib>
using namespace metal;

// Classic mode GLSL source mapping.
// - introKernel: shaders/glsl/rainPass.intro.frag.glsl.
// - raindropKernel: shaders/glsl/rainPass.raindrop.frag.glsl.
// - symbolKernel: shaders/glsl/rainPass.symbol.frag.glsl.
// - effectKernel: shaders/glsl/rainPass.effect.frag.glsl.
// - fs_main: shaders/glsl/rainPass.frag.glsl.
// - fs_highpass: shaders/glsl/bloomPass.highPass.frag.glsl.
// - fs_blur: shaders/glsl/bloomPass.blur.frag.glsl.
// - fs_composite: bloomPass.combine.frag.glsl + palettePass.frag.glsl.
//
// Known fidelity tradeoffs in this port.
// - fs_blur intentionally scales the sample step by 0.65 for sharper glyphs.
// - fs_composite merges bloom combine and palette mapping into one pass.

// Defines the fullscreen vertex format used by render passes.
struct VertexIn {
  float2 position [[attribute(0)]];
  float2 uv [[attribute(1)]];
};

// Carries clip-space position and UVs from vertex to fragment shaders.
struct VertexOut {
  float4 position [[position]];
  float2 uv;
};

// Provides glyph rendering uniforms shared with the main fragment shader.
struct MSDFUniforms {
  float2 gridSize;
  float2 screenSize;
  float glyphHeightToWidth;
  float glyphScale;
  float msdfPxRange;
  float time;
  float2 atlasGridSize;
};

// Provides blur sampling state for the separable bloom blur pass.
struct BlurUniforms {
  float2 texelSize;
  float2 direction;
};

// Returns deterministic pseudo-random noise for a 2D coordinate.
float randomFloat(float2 uv) {
  const float a = 12.9898;
  const float b = 78.233;
  const float c = 43758.5453;
  float dt = dot(uv, float2(a, b));
  float sn = fmod(dt, 3.14159265359);
  return fract(sin(sn) * c);
}

// Applies the wobble function used by the original rain timing logic.
float wobble(float x) {
  return x + 0.3 * sin(1.41421356237 * x) + 0.2 * sin(2.2360679775 * x);
}

// Updates the intro column timing state texture.
// Ported from shaders/glsl/rainPass.intro.frag.glsl.
kernel void introKernel(
  texture2d<half, access::read> previousIntro [[texture(0)]],
  texture2d<half, access::write> introOut [[texture(1)]],
  constant float &time [[buffer(0)]],
  constant uint &tick [[buffer(1)]],
  constant uint &skipIntro [[buffer(2)]],
  constant int2 &gridSize [[buffer(3)]],
  uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= (uint)gridSize.x) { return; }
  float simTime = time;
  float columnTimeOffset;
  int column = int(gid.x);

  // Skip-intro mode immediately marks every column as fully progressed.
  if (skipIntro != 0) {
    introOut.write(half4(2.0, 0.0, 0.0, 0.0), uint2(gid.x, 0));
    return;
  }

  // Keep the two "hero" columns from the original intro choreography.
  if (column == gridSize.x / 2) {
    columnTimeOffset = -1.0;
  } else if (column == int(float(gridSize.x) * 0.75)) {
    columnTimeOffset = -2.0;
  } else {
    // Use deterministic per-column offsets for stable replay behavior.
    columnTimeOffset = randomFloat(float2(float(column), 0.0)) * -4.0;
    columnTimeOffset += (sin(float(column) / float(gridSize.x) * 3.14159265359) - 1.0) * 2.0 - 2.5;
  }
  float introTime = (simTime + columnTimeOffset) * 0.3 / float(gridSize.y) * 100.0;
  introOut.write(half4(introTime, 0.0, 0.0, 0.0), uint2(gid.x, 0));
}

// Computes brightness for one glyph cell in the rain field.
float getRainBrightness(float simTime, float2 glyphPos) {
  float columnTimeOffset = randomFloat(float2(glyphPos.x, 0.0)) * 1000.0;
  float columnSpeedOffset = randomFloat(float2(glyphPos.x + 0.1, 0.0)) * 0.5 + 0.5;
  float columnTime = columnTimeOffset + simTime * 0.3 * columnSpeedOffset;
  float rainTime = (glyphPos.y * 0.01 + columnTime) / 0.75;
  rainTime = wobble(rainTime);
  return 1.0 - fract(rainTime);
}

// Updates per-cell rain brightness, cursor state, and activation state.
// Ported from shaders/glsl/rainPass.raindrop.frag.glsl.
kernel void raindropKernel(
  texture2d<half, access::read> introState [[texture(0)]],
  texture2d<half, access::read> prevState [[texture(1)]],
  texture2d<half, access::write> outState [[texture(2)]],
  constant float &time [[buffer(0)]],
  constant uint &tick [[buffer(1)]],
  constant uint &skipIntro [[buffer(2)]],
  constant int2 &gridSize [[buffer(3)]],
  uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= (uint)gridSize.x || gid.y >= (uint)gridSize.y) { return; }
  float simTime = time;
  float2 glyphPos = float2(float(gid.x), float(gid.y));

  // Evaluate local brightness and neighbor brightness for cursor detection.
  float brightness = getRainBrightness(simTime, glyphPos);
  float brightnessBelow = getRainBrightness(simTime, glyphPos + float2(0.0, -1.0));

  // Gate activation based on intro progression, unless skip-intro is enabled.
  float introProgress = introState.read(uint2(gid.x, 0)).x - (1.0 - glyphPos.y / float(gridSize.y));
  float introProgressBelow =
    introState.read(uint2(gid.x, 0)).x -
    (1.0 - (glyphPos.y - 1.0) / float(gridSize.y));
  bool activated = bool(prevState.read(gid).z) || (skipIntro != 0) || introProgress > 0.0;
  bool activatedBelow = (skipIntro != 0) || introProgressBelow > 0.0;
  bool cursor = (brightness > brightnessBelow) || (activated && !activatedBelow);

  // Preserve channel packing expected by the render pass.
  float previousBrightness = prevState.read(gid).x;
  brightness = mix(previousBrightness, brightness, 1.0);
  outState.write(half4(brightness, float(cursor), float(activated), introProgress), gid);
}

// Updates per-cell glyph index and glyph age used for symbol animation.
// Ported from shaders/glsl/rainPass.symbol.frag.glsl.
kernel void symbolKernel(
  texture2d<half, access::read> raindropState [[texture(0)]],
  texture2d<half, access::read> prevState [[texture(1)]],
  texture2d<half, access::write> outState [[texture(2)]],
  constant float &time [[buffer(0)]],
  constant uint &tick [[buffer(1)]],
  constant int2 &gridSize [[buffer(2)]],
  uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= (uint)gridSize.x || gid.y >= (uint)gridSize.y) { return; }
  float simTime = time;
  float2 screenPos = float2(float(gid.x) / float(gridSize.x), float(gid.y) / float(gridSize.y));
  float previousSymbol = prevState.read(gid).x;
  float previousAge = prevState.read(gid).y;

  // Re-seed symbols when the simulation resets.
  bool resetGlyph = tick <= 1;
  if (resetGlyph) {
    previousAge = randomFloat(screenPos + 0.5);
    previousSymbol = floor(57.0 * randomFloat(screenPos));
  }

  // Age symbols and rotate when the age wraps.
  float age = previousAge;
  float symbol = previousSymbol;
  if ((tick % 1) == 0) {
    age += 0.03;
    if (age >= 1.0) {
      symbol = floor(57.0 * randomFloat(screenPos + simTime));
      age = fract(age);
    }
  }
  outState.write(half4(symbol, age, 0.0, 0.0), gid);
}

// Updates placeholder effect state for compatibility with the source pipeline.
// Ported from shaders/glsl/rainPass.effect.frag.glsl.
kernel void effectKernel(
  texture2d<half, access::read> raindropState [[texture(0)]],
  texture2d<half, access::read> prevState [[texture(1)]],
  texture2d<half, access::write> outState [[texture(2)]],
  constant float &time [[buffer(0)]],
  constant uint &tick [[buffer(1)]],
  constant int2 &gridSize [[buffer(2)]],
  uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= (uint)gridSize.x || gid.y >= (uint)gridSize.y) { return; }
  outState.write(half4(1.0, 0.0, 0.0, 0.0), gid);
}

// Emits a fullscreen triangle-strip vertex with pass-through UVs.
vertex VertexOut vs_fullscreen(VertexIn in [[stage_in]]) {
  VertexOut out;
  out.position = float4(in.position, 0.0, 1.0);
  out.uv = in.uv;
  return out;
}

// Computes the median channel for MSDF signed distance decoding.
float median3(float3 v) {
  return max(min(v.r, v.g), min(max(v.r, v.g), v.b));
}

// Maps grayscale brightness into the matrix green palette ramp.
float3 paletteColor(float t) {
  float3 c0 = float3(0.0, 0.0, 0.0);
  float3 c1 = float3(0.092, 0.38, 0.02);
  float3 c2 = float3(0.538, 0.97, 0.43);
  float3 c3 = float3(0.692, 0.98, 0.62);
  if (t <= 0.2) { return mix(c0, c1, t / 0.2); }
  if (t <= 0.7) { return mix(c1, c2, (t - 0.2) / 0.5); }
  if (t <= 0.8) { return mix(c2, c3, (t - 0.7) / 0.1); }
  return c3;
}

// Renders rain glyph energy into base render targets using MSDF sampling.
// Ported from shaders/glsl/rainPass.frag.glsl (non-volumetric branch).
fragment float4 fs_main(VertexOut in [[stage_in]],
                         constant MSDFUniforms &u [[buffer(0)]],
                         texture2d<float> atlas [[texture(0)]],
                         sampler atlasSampler [[sampler(0)]],
                         texture2d<half, access::read> raindropTex [[texture(1)]],
                         texture2d<half, access::read> symbolTex [[texture(2)]],
                         texture2d<half, access::read> effectTex [[texture(3)]]) {
  // Convert screen UVs into logical glyph grid coordinates.
  float2 uv = (in.uv - 0.5) / u.screenSize + 0.5;
  float2 uvAdj = float2(uv.x, 1.0 - uv.y);
  uvAdj.y /= u.glyphHeightToWidth;
  float2 gridUV = uvAdj * u.gridSize;
  int2 gridCoord = int2(gridUV);
  gridCoord.x = clamp(gridCoord.x, 0, int(u.gridSize.x) - 1);
  gridCoord.y = clamp(gridCoord.y, 0, int(u.gridSize.y) - 1);

  // Read packed state channels from compute passes.
  float4 raindrop = float4(raindropTex.read(uint2(gridCoord)).xyzw);
  float4 symbol = float4(symbolTex.read(uint2(gridCoord)).xyzw);
  float4 effect = float4(effectTex.read(uint2(gridCoord)).xyzw);
  float activated = raindrop.z;
  if (activated <= 0.0) { return float4(0.0); }
  float brightness = raindrop.x + max(0.0, 1.0 - raindrop.w * 5.0);
  float base = brightness * 1.1 + -0.5;
  base = base * effect.x + effect.y;
  base = max(base, 0.0);

  // Resolve atlas cell coordinates for the current glyph index.
  bool isCursor = raindrop.y > 0.5;
  float2 cellUV = fract(uvAdj * u.gridSize);
  cellUV = (cellUV - 0.5) / u.glyphScale + 0.5;
  cellUV = clamp(cellUV, 0.0, 1.0);
  uint glyphIndex = uint(symbol.x + 0.5);
  uint gridX = glyphIndex % uint(u.atlasGridSize.x);
  uint gridY = glyphIndex / uint(u.atlasGridSize.x);
  float2 glyphCell = float2(gridX, (uint(u.atlasGridSize.y) - 1u - gridY));
  float2 atlasUV = (cellUV + glyphCell) / u.atlasGridSize;

  // Decode MSDF alpha and output separate normal/cursor channels.
  float3 sample = atlas.sample(atlasSampler, atlasUV).rgb;
  float signedDistance = median3(sample);
  float2 unitRange = u.msdfPxRange / float2(atlas.get_width(), atlas.get_height());
  float2 screenTexSize = 1.0 / fwidth(atlasUV);
  float screenPxRange = max(0.5 * dot(unitRange, screenTexSize), 1.0);
  float screenPxDistance = screenPxRange * (signedDistance - 0.5);
  float alpha = clamp(screenPxDistance + 0.5, 0.0, 1.0);
  float glyphBrightness = base * alpha * activated;
  float normalChannel = isCursor ? 0.0 : glyphBrightness;
  float cursorChannel = isCursor ? glyphBrightness : 0.0;
  return float4(normalChannel, cursorChannel, 0.0, 1.0);
}

// Extracts bright pixels for the bloom chain.
// Ported from shaders/glsl/bloomPass.highPass.frag.glsl.
fragment float4 fs_highpass(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler texSampler [[sampler(0)]]) {
  float highPassThreshold = 0.1;
  float2 sampleUV = float2(in.uv.x, 1.0 - in.uv.y);
  float4 color = tex.sample(texSampler, sampleUV);
  if (color.r < highPassThreshold) { color.r = 0.0; }
  if (color.g < highPassThreshold) { color.g = 0.0; }
  if (color.b < highPassThreshold) { color.b = 0.0; }
  return color;
}

// Applies one axis of the separable bloom blur.
// Ported from shaders/glsl/bloomPass.blur.frag.glsl.
fragment float4 fs_blur(VertexOut in [[stage_in]],
                         constant BlurUniforms &u [[buffer(0)]],
                         texture2d<float> tex [[texture(0)]],
                         sampler texSampler [[sampler(0)]]) {
  float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
  float2 aspectCorrect = u.texelSize.x > u.texelSize.y
    ? float2(u.texelSize.x / u.texelSize.y, 1.0)
    : float2(1.0, u.texelSize.y / u.texelSize.x);
  float maxDim = max(1.0 / u.texelSize.x, 1.0 / u.texelSize.y);

  // Keep a reduced blur footprint to preserve glyph sharpness.
  float2 step = u.direction / maxDim * aspectCorrect * 0.65;
  float4 color = tex.sample(texSampler, uv) * 0.442;
  color += tex.sample(texSampler, uv + step) * 0.279;
  color += tex.sample(texSampler, uv - step) * 0.279;
  return color;
}

// Combines base and bloom textures and applies palette mapping and grain.
// Ported from bloomPass.combine.frag.glsl and palettePass.frag.glsl.
fragment float4 fs_composite(VertexOut in [[stage_in]],
                              constant float &time [[buffer(0)]],
                              texture2d<float> baseTex [[texture(0)]],
                              texture2d<float> bloom0 [[texture(1)]],
                              texture2d<float> bloom1 [[texture(2)]],
                              texture2d<float> bloom2 [[texture(3)]],
                              texture2d<float> bloom3 [[texture(4)]],
                              texture2d<float> bloom4 [[texture(5)]],
                              sampler texSampler [[sampler(0)]]) {
  // Accumulate weighted bloom from the five-level pyramid.
  float2 uv = in.uv;
  float3 bloom = bloom0.sample(texSampler, uv).rgb * 0.96549;
  bloom += bloom1.sample(texSampler, uv).rgb * 0.92832;
  bloom += bloom2.sample(texSampler, uv).rgb * 0.88790;
  bloom += bloom3.sample(texSampler, uv).rgb * 0.84343;
  bloom += bloom4.sample(texSampler, uv).rgb * 0.79370;
  float3 brightness = baseTex.sample(texSampler, uv).rgb + bloom * 0.60;

  // Apply grain before palette mapping to match the source ordering.
  float2 fragCoord = in.position.xy;
  float noise = randomFloat(fragCoord) + time;
  noise = fract(noise);
  brightness = max(brightness - noise * 0.05 / 3.0, 0.0);

  // Reconstruct final matrix color from normal/cursor/white channels.
  float3 color = paletteColor(clamp(brightness.r, 0.0, 1.0));
  color += min(float3(0.756, 1.0, 0.46) * 2.0 * brightness.g,
              float3(1.0));
  color += min(float3(1.0) * brightness.b, float3(1.0));
  return float4(color, 1.0);
}
