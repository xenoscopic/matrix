# Matrix Metal Screensaver

This folder contains a native macOS `.saver` port of Rezmason's
"classic" Matrix code rain.

## Scope

Implemented target:
- Classic preset only.
- `skipIntro=true` and `skipIntro=false` behavior.
- Native Metal rendering in `ScreenSaverView`.

Out of scope for now:
- Other presets and alternate effects.
- Volumetric mode.
- Web runtime features.

## Project Layout

- `Matrix/MatrixView.m`: Screen saver host, state update kernels, and render
  pipeline.
- `Matrix/MatrixView.h`: Public view declaration.
- `Matrix/Resources/matrixcode_msdf.png`: Classic glyph atlas.
- `Matrix.xcodeproj`: Build configuration for the `.saver` bundle.

## Rendering Pipeline

Per frame, the renderer runs:

1. Compute state update kernels:
- Intro progression.
- Raindrop brightness and cursor detection.
- Symbol cycling.
- Effect state.

2. Glyph pass:
- MSDF glyph rendering into an offscreen HDR render target.

3. Bloom pyramid:
- High-pass filter.
- Horizontal blur.
- Vertical blur.
- Repeated across 5 downscaled levels.

4. Composite pass:
- Bloom accumulation.
- Palette mapping.
- Cursor highlight.
- Final presentation to the drawable.

## Porting Strategy

The implementation maps the original WebGL shaders to Metal kernels and
fragment stages with equivalent state textures and pass ordering.

Direct mappings are documented in `MatrixView.m` in `buildMetalPipeline`.

Important adaptation details:
- The classic non-volumetric screen aspect behavior is preserved with
  `screenSize` UV remapping.
- Glyph atlas upload uses vertical flip to match WebGL `flipY` semantics.
- Bloom uses half-float offscreen textures to preserve headroom.

## Configuration

Current configuration sheet option:
- `Skip Intro` (`ScreenSaverDefaults` key: `SkipIntro`).

Behavior:
- Enabled: starts in steady-state rain mode.
- Disabled: runs intro progression before full activation.

## Build (Release)

From repository root:

```bash
xcodebuild \
  -project screensaver/Matrix/Matrix.xcodeproj \
  -scheme Matrix \
  -configuration Release \
  -derivedDataPath /tmp/matrix-release \
  build
```

Result bundle:
- `/tmp/matrix-release/Build/Products/Release/Matrix.saver`

## Install

Install for current user:

```bash
mkdir -p "$HOME/Library/Screen Savers"
cp -R /tmp/matrix-release/Build/Products/Release/Matrix.saver \
  "$HOME/Library/Screen Savers/"
```

Then open System Settings:
- `Screen Saver`.
- Select `Matrix`.
- Open options to toggle `Skip Intro`.

## Known Fidelity Gaps

Current implementation is close, but not fully bit-exact with the browser
reference.

Known differences:
- Palette pass is merged into the final composite pass instead of being a
  separate pass.
- Bloom blur footprint is intentionally tightened from strict parity to keep
  glyphs crisper at higher bloom intensity.
- State texture sampling in the rain render path uses explicit cell reads
  instead of bilinear `texture2D` sampling semantics.
- Glyph cores still appear slightly softer than the web reference, even with
  bloom disabled and with the same `matrixcode_msdf.png` atlas bytes.
  Root cause is still unresolved.

## Suggested Future Work

- Make bloom radius and strength configurable in the options UI.
- Add a debug mode to visualize intermediate render targets.
- Add a fidelity test checklist with captured reference frames.
