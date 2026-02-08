# Matrix Screensaver Agent Handoff

This document is for future coding agents reviewing or extending the
`screensaver/` port.

## Goal And Scope

Current scope is intentionally narrow:

- Reproduce Rezmason "classic" Matrix rain style.
- Support both intro variants:
  - `skipIntro=false` (intro enabled).
  - `skipIntro=true` (intro skipped).
- Use native Metal in a macOS `.saver`.

Out of scope right now:

- Other presets.
- Volumetric mode.
- Browser/runtime features outside the classic visual pipeline.

## Reference Outputs

Visual references used for fidelity:

- https://rezmason.github.io/matrix
- https://rezmason.github.io/matrix/?skipIntro=false

## Where To Start Reading

Read these files first:

- `screensaver/Matrix/Matrix/MatrixView.m`
- `screensaver/Matrix/Matrix/MatrixView.metal`
- `screensaver/README.md`
- `screensaver/Makefile`

## Current Architecture

Host and render orchestration:

- `MatrixView.m` owns `CAMetalLayer`, textures, pipelines, and per-frame
  encoding.
- Simulation state uses ping-pong textures:
  - intro state.
  - raindrop state.
  - symbol state.
  - effect state.
- Render flow per frame:
  1. Compute pass updates (4 kernels).
  2. Glyph render pass.
  3. 5-level bloom pyramid:
     - high-pass.
     - horizontal blur.
     - vertical blur.
  4. Composite pass to drawable.

Shader location:

- All active shader code is in
  `screensaver/Matrix/Matrix/MatrixView.metal`.
- `MatrixView.m` loads a precompiled default library and resolves functions
  by name.

## Key Implemented Fixes And Decisions

These are important context from recent fidelity work:

- Removed incorrect mirrored/rain-direction artifacts.
- Corrected glyph orientation and texture handling.
- Brought glyph aspect back toward classic reference behavior.
- Added state reset behavior to avoid simulation carry-over between runs.
- Tuned bloom to reduce over-blur while preserving glow:
  - `fs_blur` uses a reduced footprint factor (`0.65`).
  - `fs_composite` uses bloom scale (`0.60`).
- Dither/grain is applied in composite using fragment-position-based noise.
- Moved from runtime shader source strings to precompiled `.metal` shaders.

## GLSL To Metal Mapping

Mapping is documented inline in `MatrixView.metal`, and also summarized in
`buildMetalPipeline` comments in `MatrixView.m`.

Core mapping:

- `introKernel` <- `rainPass.intro.frag.glsl`
- `raindropKernel` <- `rainPass.raindrop.frag.glsl`
- `symbolKernel` <- `rainPass.symbol.frag.glsl`
- `effectKernel` <- `rainPass.effect.frag.glsl`
- `fs_main` <- `rainPass.frag.glsl` (non-volumetric branch)
- `fs_highpass` <- `bloomPass.highPass.frag.glsl`
- `fs_blur` <- `bloomPass.blur.frag.glsl`
- `fs_composite` <- `bloomPass.combine.frag.glsl` + `palettePass.frag.glsl`

## Known Fidelity Tradeoffs

Current intentional differences from strict WebGL parity:

- Palette is merged into composite instead of a separate pass.
- Bloom blur footprint is tightened for crisper glyphs at useful bloom gain.
- Rain-state sampling is explicit cell reads, not bilinear `texture2D`
  semantics.

## Build And Install

From `screensaver/`:

- `make` runs `build`, and `build` depends on `clean`.
- `make clean` removes the entire local `build/` directory.
- `make build` performs a Release build via `xcodebuild`.
- `make install` depends on `build` and copies `Matrix.saver` to
  `~/Library/Screen Savers`.

## Icon Note

If System Settings does not show an icon preview for the saver, use:

- A `.icns` resource in bundle resources.
- `CFBundleIconFile` in Info.plist build settings (for generated plist,
  set `INFOPLIST_KEY_CFBundleIconFile`).

## Re-Review Checklist For Future Agents

When reviewing changes, check in this order:

1. Correctness:
   - No mirrored rain direction.
   - No per-glyph vertical inversion.
   - No startup state carry-over artifacts.
2. Fidelity:
   - Compare both reference URLs above.
   - Validate intro and skip-intro modes separately.
   - Check glyph sharpness versus glow balance.
3. Performance:
   - Confirm all heavy work remains in Metal passes.
   - Avoid unnecessary CPU allocations per frame.
4. Build:
   - Ensure Release build succeeds from Makefile and Xcode CLI.
5. Stability:
   - Keep shader function names stable with pipeline lookup names unless
     both sides are updated together.

## Practical Guidance For Future Agents

- Prefer edits in `MatrixView.metal` and `MatrixView.m`.
- Keep comments and mapping notes in sync when behavior changes.
- Preserve classic-only scope unless explicitly asked to expand.
- Avoid editing Xcode metadata files unless required by the task.
