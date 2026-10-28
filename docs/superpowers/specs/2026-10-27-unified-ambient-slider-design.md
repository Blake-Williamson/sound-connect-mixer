# Unified Ambient / Noise-Canceling Slider — Design

**Date:** 2026-10-27
**Status:** Approved design, pending implementation plan
**App:** open-sound-connect (published as Blake-Williamson/sound-connect-mixer)

## Summary

Replace the three-button Ambient Sound Control (Noise Canceling / Ambient Sound / Off)
on the **My Device** page with **one continuous stepped slider** spanning
**Noise Canceling → Ambient 0–20**, plus a small **Off** button. This lets the user dial in
the exact isolation/transparency level that suits their ears instead of picking a discrete mode.

No model or protocol changes — the Sony headphones already support a 0–20 ambient level; this is
a UI/UX change over the existing `controller.requestNoise` write path.

## Hardware reality (why this is the right shape)
Sony's noise canceling is **on/off**, not a percentage — there is no "50% ANC." The continuous
axis the hardware exposes is the **ambient sound level (0–20)**. So the single slider maps:
Noise Canceling (max isolation) → Ambient level 0 → … → Ambient level 20 (fully open).

## Scope
**In scope:** the unified slider + Off button on the My Device "Ambient Sound Control" card;
Focus on Voice shown in the ambient range; capability-gating with a fallback to today's buttons.
**Out of scope:** changes to the Sound page / menu-bar controls; any model/protocol change;
continuous "ANC percentage" (not supported by the hardware).

## Mapping (the pure core)
For a device with ambient range `lo...hi` (XM6: 0...20), the slider is a stepped control over
integer positions `0 ... (1 + (hi - lo))`:

| Position | State |
|---|---|
| 0 | `mode = .noiseCancelling` |
| 1 … (1 + hi − lo) | `mode = .ambient`, `ambientLevel = lo + (position − 1)` |

Two pure functions (unit-tested):
- `position(for noise: NoiseControl, range: ClosedRange<Int>) -> Int`
  - `.noiseCancelling → 0`; `.ambient → 1 + (ambientLevel − lo)`, clamped to `0...(1+hi−lo)`;
    `.off`/other → the last ambient/NC position is irrelevant (Off is driven by the button; the
    slider shows position 0 when the mode isn't NC/Ambient).
- `noiseChange(forPosition pos: Int, range: ClosedRange<Int>) -> (mode: NoiseMode, ambientLevel: Int?)`
  - `pos == 0 → (.noiseCancelling, nil)`; else `(.ambient, lo + (pos − 1))` clamped to range.

## UI
On the "Ambient Sound Control" card (`MyDeviceView`):
- **Unified slider** (new `UI/AmbientSlider.swift`): a stepped slider over the position range,
  with a live label (`"Noise Canceling"` at 0, `"Ambient · N"` otherwise) and end captions
  (*Noise Canceling* ◁ ▷ *Ambient*). On change it calls `controller.requestNoise { value in … }`
  applying `noiseChange(forPosition:range:)` (set mode; set ambientLevel when ambient).
- **Off button** beside the slider → `controller.requestNoise { $0.mode = .off }`, highlighted
  when the current mode is `.off`.
- **Focus on Voice** toggle (existing) shown only when the slider is in the ambient range and
  `capabilities.noise.supportsVoiceFocus`.
- Any other supported modes besides NC/Ambient/Off (e.g. `.windReduction` on models that have it)
  render as small buttons beside Off, so no mode is lost.

**Capability-gating:** show the unified slider only when `capabilities.noise` exists with
`modes` containing both `.noiseCancelling` and `.ambient` and `ambientRange.count > 1`. Otherwise
render today's mode-button control unchanged.

**Write throttling:** reuse the existing verified path — `controller.requestNoise` coalesces via
its pending `noiseIntent`, exactly as the current ambient level slider does. Disabled when
`!controller.canWrite` or in replay.

## Testing
- **Unit (new `Tests/.../AmbientSliderMappingTests`):** `position(for:range:)` and
  `noiseChange(forPosition:range:)` round-trip and boundaries — NC↔0, ambient 0↔1, ambient
  20↔21, clamping out-of-range, non-NC/ambient → 0.
- **Manual on-device (XM6):** drag NC→Ambient smoothly and confirm the headset tracks it; Off
  button engages Off; Focus on Voice appears only in ambient; the existing button UI still shows
  for a device without the required capability.

## Files
- Create: `Sources/SoundConnect/UI/AmbientSlider.swift` (slider view + the two pure mapping funcs).
- Modify: `Sources/SoundConnect/UI/MyDeviceView.swift` (swap the card's control, capability-gated).
- Test: `Tests/SoundConnectTests/AmbientSliderMappingTests` (added to the test target).
