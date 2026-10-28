# Per-App Mixer Widget — Design

**Date:** 2026-10-27
**Status:** Approved design, pending implementation plan
**App:** open-sound-connect (Sound Connect for macOS)

## Summary

Add a **Mixer** page to Sound Connect that shows a live audio **level meter per
application** producing sound (Spotify, Brave, Zoom, …). This is **v1: read-only
metering**. It is built so a later **v2** can turn each meter row into a working
**volume slider + mute** without reshaping the code.

The implementation uses Apple's **Core Audio process-tap API** (macOS 14.4+).
Critically, v1 uses **non-muting** taps, so the app never sits in the audio
playback path — the worst-case failure is "meters don't show," never "sound
breaks."

### Why not BackgroundMusic / a virtual driver

An earlier attempt used the third-party app BackgroundMusic for per-app volume.
It installed a virtual audio driver and grabbed the headphones as a microphone,
which forced the Bluetooth headset into low-quality mono "call mode" (HFP,
16 kHz) and produced static/distortion. It has been fully uninstalled. The
process-tap approach needs **no driver and no microphone**, so that failure mode
cannot recur.

## Scope

**In scope (v1):**
- A new "Mixer" page in the left sidebar.
- Live per-app level meters for apps currently producing output audio.
- App name + icon per row.
- Works whether or not the headphones are connected (it concerns Mac audio, not
  the XM5).
- Runs for the whole app session (launch → quit).
- Permission handling, empty state, and non-fatal error states.

**Out of scope (deferred to v2):**
- Changing volume / muting (requires muting taps + an aggregate output device +
  a real-time gain mixer — the part that puts the app back in the playback
  path).
- Menu-bar meters/sliders.
- Pan control.
- Per-app persistence of volumes.

## Architecture & Components

Follows the existing codebase layering (`Transport/`, `Protocol/`, `Model/`,
`UI/`, wired via SwiftUI `@Environment`). All new audio code is quarantined in a
new `Mixer/` group and depends on nothing else in the app.

| Unit | Responsibility | Depends on | SwiftUI? |
|---|---|---|---|
| `Mixer/ProcessTapEngine.swift` | All Core Audio: discover apps making sound; build one **non-muting** aggregate tap over them; run an IO callback computing each app's peak/RMS level; emit `[(pid, level)]`. `start()` / `stop()`. | CoreAudio / AudioToolbox | No |
| `Mixer/AppAudioLevel.swift` | Value type: `pid`, `bundleID`, `displayName`, `icon`, `level` (0–1), `isPlaying`. | Foundation / AppKit | No |
| `Mixer/MixerModel.swift` | `@MainActor @Observable` (mirrors `HeadphoneController`). Owns the engine; throttles/smooths updates (~30 Hz); resolves pid → name & icon via `NSRunningApplication`; tracks permission state. Exposes `apps: [AppAudioLevel]`. | ProcessTapEngine, AppKit | No (state only) |
| `UI/MixerView.swift` | The sidebar page: one row per app (icon · name · meter bar); empty / permission / error states. | MixerModel, Theme | Yes |

**Hooks into existing code (small, following current patterns):**
- `UI/RootView.swift` — add a `.mixer` case to the `AppPage` enum: title
  "Mixer", an SF Symbol, a keyboard shortcut, and **`needsConnection = false`**
  so the page works with the headphones off.
- `App/SoundConnectApp.swift` — create one `MixerModel` and inject it with
  `.environment(...)`, like the other controllers.
- `Resources/Info.plist` — add the audio-capture usage string macOS requires
  for taps.

**Seams (interfaces):**
- **Engine → Model:** engine emits raw `[(pid, level)]` from the audio thread;
  the model hops to the main actor, smooths, and maps to `[AppAudioLevel]`.
- **Model → UI:** the view reads the observable `apps` array and draws. No Core
  Audio in the view.
- **`AudioTapProviding` protocol:** the thin Core Audio calls sit behind a
  protocol so the engine's orchestration logic can be unit-tested with a fake
  provider.

## Data Flow & Lifecycle

**Active for the whole app session** (launch → quit). This supports a future
menu-bar meter and is the user's chosen behavior. The consequence is that the
macOS permission prompt appears on first launch of this version (handled below).

1. App launches → `MixerModel.start()` → `ProcessTapEngine.start()`.
2. Permission check (see below). If needed, macOS shows its one-time "record
   this computer's audio" prompt.
3. **Discover apps:** read the system process list, keep those currently
   producing output audio, capture each one's **pid + bundle id**.
4. **Build the tap:** create a **non-muting** tap over those processes wrapped in
   a private **aggregate device** with an IO callback. Non-muting = audio keeps
   playing untouched.
5. **Audio thread → levels:** each IO callback (real-time thread) computes
   peak/RMS per app and writes into a **lock-free slot** — no allocation, no
   locks, no main-thread work in the callback.
6. **Publish to UI:** ~30×/sec the model reads those values on the main actor,
   applies smoothing (fast attack, gentle decay), resolves pid → name & icon,
   and updates `apps`.
7. **Apps come & go:** a property listener fires when the set of audio-playing
   processes changes; the engine **rebuilds the tap (debounced ~250 ms)** so new
   apps appear and silent ones fade, with stable row ordering.
8. App quits → `stop()` tears down the IO callback, destroys the aggregate
   device and tap, releases everything.

**Critical boundary:** the audio-thread callback only does math-and-store into
the lock-free slot. All user-facing work (naming, icons, smoothing, SwiftUI)
happens on the main actor. This keeps audio glitch-free and is the discipline
v2's gain mixer will require.

## Permissions & Error Handling

**Permission:** Core Audio taps require macOS audio-recording consent. Because
the engine starts at launch, the prompt appears the first time the app runs
after installing this version.
- `Info.plist` gets the required usage string.
- The build script already signs with a **stable identifier** (how the Bluetooth
  grant persists across rebuilds), so the audio grant **also persists across
  rebuilds** — no re-approving each build.

**Permission states drive the Mixer page:**
- **Granted** → meters run.
- **Not-yet-asked** → short "Enable per-app audio" explainer with a button that
  triggers the prompt (never a surprise prompt).
- **Denied** → calm explainer + "Open Privacy & Security settings" button;
  engine idle; nothing else in the app affected.

**Headline safety property of v1:** taps are **unmuted**, so the engine is never
in the playback path. Worst case is "meters don't show," never "sound breaks."

**Non-fatal failure modes:**

| Situation | Behavior |
|---|---|
| Tap / aggregate-device creation errors | "Mixer unavailable" state, log details, retry on next launch — no crash |
| An app quits mid-session | Reconcile list, drop its row |
| Nothing is playing | Friendly empty state ("Nothing is playing right now") |
| Repeated IO-callback errors | Engine stops cleanly and surfaces a message rather than spinning |
| macOS < 14.4 (guard) | Feature hidden; app targets macOS 15, so N/A here |

**Error visibility:** failures are logged through the app's existing diagnostics,
consistent with how the rest of the app reports issues.

## Testing

Logic is pushed out of the untestable Core Audio shell (behind
`AudioTapProviding`) so a **fake provider** can drive the engine in unit tests.

**Unit tests (existing `Tests` target):**
- **RMS/peak math:** known buffers → silence ≈ 0, full-scale tone ≈ 1.
- **Smoothing:** pure attack/decay function → deterministic assertions.
- **List reconciliation:** old set + new set → correct rows, stable ordering,
  stopped apps fade.
- **pid → name/icon:** `NSRunningApplication` behind an injectable type, mocked.

**Manual verification checklist (real Mac):**
- Spotify + Brave + Zoom each move their own bar.
- Stop one → its bar falls, row fades.
- Deny permission → explainer; grant → meters.
- Headphones off → page still works.
- Nothing playing → empty state.
- CPU near-idle; no audio glitches while tapping.

## v2 Forward-Compatibility (designed for, not built now)

- The **same `ProcessTapEngine`** flips non-muting → **muting + gain**: tap with
  mute-when-tapped, an aggregate device that also includes the real output
  device, and an IO callback that applies per-app gain and mixes to output.
- `MixerModel` grows `volume` / `isMuted` per app; the meter row grows a
  **slider + mute toggle** (the approved mock).
- **v2 safety, reserved now:** a hard **bypass** (any render underrun/error →
  instantly stop muting so apps play directly; never leave the user silent); a
  default-off opt-in; optionally XPC-process isolation for the render loop.
- The seams (engine → per-pid data, model → per-app state, view → rows) do not
  change shape, so meters becoming sliders is an extension, not a rewrite.

## Licensing / Attribution

This feature uses Apple's public Core Audio APIs only. It does **not** use or
copy code from BackgroundMusic (GPLv2) or any other project, so it imposes no
additional license obligations on open-sound-connect (MIT).
