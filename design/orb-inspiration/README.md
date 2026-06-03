# Orb redesign — visual target

Reference images for evolving the voice orb toward the **JARVIS filament / HUD**
aesthetic: a glowing amber-orange energy sphere woven from fine light filaments,
with an intense hot core, a translucent shell, and a faint surrounding HUD ring.

| File | Notes |
|---|---|
| `jarvis-orb-inspo-1.jpeg` | Dense filament sphere, bright molten core, dark backdrop, subtle corner HUD marks |
| `jarvis-orb-inspo-2.jpeg` | Same energy-ball in situ, warmer amber filaments, soft volumetric glow |

## What to pull from these
- **Palette:** deep black background → amber/orange filaments → near-white hot core.
- **Structure:** thousands of thin curved strands forming a sphere, not a solid ball.
- **Motion:** strands should stir and the core should pulse with Jarvis's voice level
  (the orb already reacts to playback level — keep that, restyle the look).
- **HUD:** faint concentric ring + a few corner ticks, low opacity, never busy.

## Current implementation
`Jarvis/Views/OrbView.swift` — SceneKit energy bubble (glowing core + translucent
shell + additive particle halo, scale/glow driven by audio level). This is v1; the
goal is to push it toward the filament look above while keeping the voice-reactive
behaviour and blue-listening / amber-speaking states.
