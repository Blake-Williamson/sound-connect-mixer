# Per-App Mixer v2 — Volume Control & App Identification — Design

**Date:** 2026-10-27
**Status:** Approved design, pending implementation plan
**App:** open-sound-connect (Sound Connect for macOS)
**Builds on:** v1 per-app metering (merged to main) — see
`2026-10-27-per-app-mixer-widget-design.md`.

## Summary

Extend the Mixer from read-only meters to **per-app volume control**, and fix
**app identification** so rows show real apps (Zoom, Brave Browser, Spotify,
"Video call") instead of helper/daemon names like `avconferenced` or `PID 24598`.

Volume control is **opt-in** behind a master toggle. OFF (default) = exactly v1:
non-muting taps, nothing in the audio path, zero risk. ON = a single muting
aggregate "mixer" device re-mixes each app at a chosen gain and plays the result
to the real output device. An automatic **bypass** restores normal audio on any
failure or toggle-off.

### Decisions (from brainstorming)

- **Volume model:** 0–100% attenuation fader per app; 100% = the app's normal
  volume (its max). No boost above 100% (avoids distortion). Louder-relative =
  lower the others.
- **Identification:** one row per app with real name + icon, merging all of an
  app's helper processes. Shared call audio (the `avconferenced` daemon) shown
  as one friendly "Video call" row.
- **Persistence:** per-app levels remembered by identity (bundle id / daemon
  label) across relaunches; untouched apps stay at 100%.
- **Safety:** opt-in master toggle, OFF by default; auto-bypass on any glitch.

## Scope

**In scope (v2):**
- App identity resolution (helper/daemon → owning app) with names + icons.
- One-row-per-app grouping; volume fans out to all of an app's processes.
- A master "Volume control" toggle (opt-in), remembered across launches.
- Per-app 0–100% volume sliders when enabled; live pre-gain meters retained.
- The muting-tap + single-aggregate mixer with per-app gain and hard bypass.
- Per-app volume persistence (stable identities only).
- Non-fatal error handling that always preserves/restores audio.

**Out of scope:**
- Volume boost above 100%.
- Per-app EQ, pan, routing to different output devices.
- A separate mute button (0% serves as mute).
- Menu-bar sliders.

## Architecture & Components

v2 extends the v1 units rather than replacing them. The engine gains a second
mode; the model gains grouping + volume; a new identity unit fixes naming.

**Engine modes (same `ProcessTapEngine`, same `AudioTapProviding` seam):**
- **Metering mode** (toggle OFF) = v1: non-muting per-process taps, nothing in
  the playback path. Zero risk.
- **Mixing mode** (toggle ON): tear down metering taps; build ONE muting
  aggregate device (all app taps as input + the real output device as output)
  with a single render loop that applies each app's gain, mixes, and plays to the
  real device. The same pass computes per-app pre-gain RMS so meters keep working.
  Toggling off tears this down → instant normal audio (the hard bypass).

**New / changed units:**

| Unit | Role | New? |
|---|---|---|
| `Mixer/AppIdentity.swift` | Value type: `key`, `displayName`, `kind: .app(bundleID)/.daemon(label)/.unknown`. | new |
| `Mixer/AppIdentityResolver.swift` | pid → `AppIdentity` (responsibility API → parent-walk → self → daemon map → unknown), behind `AppIdentityResolving`. | new |
| `Mixer/MixerRow.swift` | Grouped app row: `identityKey`, name, icon source, level, isPlaying, volume, member pids. | new |
| `Mixer/VolumeStore.swift` | Load/save per-identity volumes in `UserDefaults`. | new |
| `Mixer/AudioTapProviding.swift` | Add `setVolumeControlEnabled(_:)`, `setGains([pid_t:Float])`, `onStatusChange`. | extend |
| `Mixer/ProcessTapEngine.swift` | Add mixing mode (muting aggregate + gain render loop + bypass), gain store, status. | extend |
| `Mixer/MixerModel.swift` | Group readings by identity into rows; own the toggle, per-row volume, status; persist + push gains. | extend |
| `UI/MixerView.swift` | Master toggle, slider rows (when ON), bypass banner. | extend |

**Seams:** volume flows **down** (model → `engine.setGains`), levels/status flow
**up** (engine → model → view). The identity resolver is injected into the model
(protocol) so grouping stays unit-testable with a fake.

## App Identification

`AppIdentity` (pure, Equatable; icon is a view concern, not stored):
```
key: String          // stable grouping key
displayName: String  // "Zoom", "Brave Browser", "Video call", "PID 24598"
kind: .app(bundleID: String) | .daemon(label: String) | .unknown
```

`AppIdentityResolver.identity(forPID:)` — first hit wins:
1. **Responsible process** — `responsibility_get_pid_responsible_for_pid(pid)`
   (via `dlsym`; skipped if unavailable). Different pid that is a regular app →
   that app. `key = bundleID`.
2. **Parent-process walk** — public `sysctl(KERN_PROC_PID)` up the parent chain
   to the first regular `NSRunningApplication` (catches browser helpers).
   `key = bundleID`.
3. **Self** — the pid itself is a regular app → use it.
4. **Known-daemon map** — small table (`avconferenced → "Video call"`; extended
   only as needed). → `.daemon(label)`, `key = "daemon:<name>"`.
5. **Fallback** — clean `proc_name()`; `.unknown`, `key = "pid:<pid>"`,
   name = that or "PID <pid>".

**Grouping:** rows keyed by `identity.key`; pids with the same key merge into one
row carrying its member pids. Combined meter level = **max** across the app's
streams (never overflows).

**Icon:** derived in the view from `kind` — `.app(bundleID)` → real app icon
(`NSWorkspace`/`NSRunningApplication`); `.daemon`/`.unknown` → an SF Symbol.

**Performance:** resolution runs once per pid, on the main actor, when a pid
first appears (never on the audio thread), cached `pid → AppIdentity`; entries
drop when a pid disappears.

**Testability:** `AppIdentityResolving` protocol + injected primitives
(responsible-pid, parent-pid, isRegularApp, procName, daemon-map) make the
pipeline order unit-testable; real syscalls verified on-device.

## The Volume Mixer Engine & Data Flow

**Mixing mode setup (toggle ON):**
1. For each audio pid, create a **muting** tap
   (`CATapDescription`, `muteBehavior = .mutedWhenTapped`, private) — silences
   the app at the real device and routes its audio to us.
2. Create ONE private aggregate device: all taps as input **+ the current
   default output device as its output sub-device**
   (`kAudioAggregateDeviceSubDeviceListKey` / `MainSubDeviceKey`).
3. Install ONE render callback: read each tap's buffers, multiply by that app's
   gain, **mix**, write to the output (→ real device). Same pass computes each
   app's **pre-gain** RMS for meters.
4. Start it. Non-tapped audio keeps playing to the real device untouched.

**Gain path (down):** slider → `MixerModel.setVolume(row, 0.45)` → persist → fan
out to member pids → `engine.setGains([pid: 0.45, …])`. Gains held in a
lock-guarded `GainStore` (v1 `LevelStore` pattern), read in the render callback
with no allocation/locks-beyond-the-store. Gain 1.0 = pass-through.

**Safety invariant:** every teardown/failure path **destroys the muting taps**,
so an app is never left muted-and-silent.

Auto-**bypass** (tear down mixer → rebuild non-muting metering → apps unmuted)
fires on: aggregate/device start failure, repeated render errors, or toggle OFF.
Status reported via `onStatusChange`: `.metering` / `.mixing` /
`.bypassed(reason)` → view banner.

**Mode transitions:**
- OFF→ON: tear down metering taps → build muting mixer → apply saved gains → start.
- ON→OFF / bypass: tear down mixer → rebuild metering taps (apps unmuted).
- Default output changes while ON → rebuild mixer around the new output device.
- Apps start/stop → existing debounced rebuild recreates taps, re-applying gains.

**Meters while mixing:** per-pid **pre-gain** RMS (the app's own activity),
independent of the fader.

This mixer is intricate and device-dependent: it compiles locally but requires
on-device verification (adjust works; toggle-off / any glitch instantly restores
normal audio; no stuck-muted app).

## UI, Persistence & the Master Toggle

**Master toggle** at the top of the Mixer page, OFF by default.

- **OFF:** rows show icon · name · meter bar (v1 look). Subtitle hints to enable.
- **ON:** rows show icon · name · **slider (0–100%)** · % label, with a thin live
  meter beneath the slider. No separate mute button (0% = off).
- **Bypass banner** when status is `.bypassed`:
  "Volume control paused — audio restored to normal."
- Permission states (granted/unknown/denied) unchanged from v1.

**Persistence (`VolumeStore`, `UserDefaults`):**
- `[identityKey: Float]`; applied when a row appears.
- **Only stable identities persist** — `.app` (bundle id) and `.daemon` (label).
  `pid:`-keyed `.unknown` rows are not saved.
- Absent → 100%.
- The **master toggle** is remembered (`@AppStorage`): first run OFF, then
  restores last choice; auto-bypass is the safety net.

**State:** `MixerModel` owns `volumeControlEnabled` (drives engine mode),
`status` (banner), and each row's `volume`; `setVolume(rowID, value)` persists +
pushes gains. No Core Audio in the view.

## Testing

**Unit-tested (pure logic; `FakeTapProvider` extended to capture
`setGains`/`setVolumeControlEnabled` and emit status; in-memory `UserDefaults`):**
- Grouping: pids + fake resolver → merge by key, level = max, member pids, stable
  order.
- Volume → gain fan-out: `setVolume(row, 0.4)` → `0.4` for every member pid.
- Persistence: round-trip; only `.app`/`.daemon` saved; `pid:` skipped; absent → 100%.
- Apply-on-appear: saved 0.4 for a bundle id → new row starts at 0.4 and pushes it.
- Toggle/status plumbing: `setVolumeControlEnabled(true)` reaches the engine;
  `.bypassed` surfaces in the model.
- Resolver ordering: injected primitives → first-hit order + `key`/`displayName`.

**Manual (on-device):**
- Correct names/icons (Zoom, Brave, Spotify, Phone; `avconferenced` → "Video call").
- Toggle ON → sliders; drag Brave down → only Brave quieter; 0% = silent;
  pre-gain meters still move.
- Toggle OFF → instant normal audio (apps unmuted, full volume).
- Switch output device while ON → rebuild, audio continues.
- Persistence survives relaunch; forced bypass → banner + sound restored; no
  distortion; no stuck-muted app.

## Error Handling

| Situation | Behavior |
|---|---|
| Mixer tap/aggregate/IO-proc create or start fails | Auto-bypass → metering, `.bypassed` banner, log; apps unmuted |
| Default output device changes/missing while ON | Rebuild around new device; rebuild fails → bypass |
| Repeated render-callback errors | Bypass |
| Resolver syscall/`dlsym` fails | Graceful fall-through to `.unknown`; no crash |
| Unresolved (`pid:`) row | Shown + adjustable for the session, not persisted |
| `VolumeStore` corrupt/missing | Ignore → default 100% |
| Permission denied | Same as v1 (no taps) |

**Overarching invariant:** every teardown/failure path destroys the muting taps,
so audio is never left silent.

## Licensing / Attribution

Uses Apple's public Core Audio APIs plus the `responsibility_get_pid_responsible_for_pid`
symbol resolved at runtime via `dlsym` (no link-time private dependency; degrades
gracefully if absent). No code copied from BackgroundMusic (GPLv2) or other
projects. open-sound-connect remains MIT.
