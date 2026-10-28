# Sound Connect + Mixer (macOS)

**Control your Sony headphones *and* set the volume of every app independently — on your Mac.**

Be on a Zoom call and listen to music at the same time, with the call, your browser, and
Spotify each at exactly the volume *you* want — turn the call up, turn YouTube down — all
while controlling your Sony WH‑1000XM headphones from the menu bar.

macOS has no built‑in per‑app volume. This project adds it, and pairs it with full Sony
headphone control, in one native app.

> **The idea:** combine a macOS *Sound Connect* (Sony headphone control) with a *per‑app audio
> mixer*, so you can run a Zoom call and music together and balance each app’s output on its own.

---

## What it does

### 🎚️ Per‑app audio Mixer
- A **live level meter for every app** making sound — with its real name and icon
  (Zoom, Brave, Spotify…). Background helper/daemon processes are rolled up to their owning app,
  and shared call audio appears as a single **“Video call.”**
- **Opt‑in per‑app volume control** (a master toggle, **off by default**): a **0–100% fader**
  for each app, **remembered across launches**.
- Built on Apple’s **Core Audio process taps** (macOS 14.4+). **No virtual audio driver, no
  kernel extension.** A hard **bypass** instantly restores normal audio if anything goes wrong.

> Note: macOS attributes browser‑tab audio to the *browser*, so all tabs of one browser share a
> single fader (this is per‑**app**, not per‑tab).

### 🎧 Sony WH‑1000XM headphone control
- Noise canceling / ambient / wind, ambient level, Focus on Voice
- Equalizer (presets + custom bands), DSEE, Speak‑to‑Chat
- Battery, codec, touch controls, scenes — from the menu bar

---

## Is it safe? (Yes — and here’s exactly why)

- **Open source.** Every line is in this repo; you can read it before you run it.
- **No install hooks or scripts.** There are no git hooks, no `npm` install steps, no
  `postinstall` — nothing runs automatically when you clone. The only thing that runs is the
  build command you type yourself (`scripts/build.sh`).
- **Minimal, honest permissions.** The app asks for exactly two things, and only for the obvious
  reasons:
  - **Bluetooth** — to talk to your Sony headphones.
  - **Audio recording** — required by macOS to read each app’s audio levels for the mixer. It is
    used **only** to meter/mix app audio; it **never** records your microphone.
- **No network, no accounts, no analytics, no telemetry.** It talks to your headphones and your
  audio locally. Nothing leaves your Mac.

### Installing
The supported, safest way is to **build it yourself** from this source (see below) — the app is
then signed on your own machine and opens with no Gatekeeper warnings.

If a prebuilt `.app` is ever shared, note it is **ad‑hoc signed, not Apple‑notarized**, so macOS
will warn on first launch; you’d need to right‑click → **Open** once to allow it. (Proper
notarization would require a paid Apple Developer account.)

---

## Requirements
- **macOS 15 or later** (the mixer’s audio taps need macOS 14.4+; developed/tested on macOS 26–27).
- **Xcode / Swift 6** to build.
- A **Sony WH‑1000XM** headset for the headphone features. (The mixer works with *any* audio.)

## Build & run
```bash
git clone https://github.com/Blake-Williamson/sound-connect-mixer.git
cd sound-connect-mixer
./scripts/build.sh
open "build/Sound Connect.app"
```
When prompted, **Allow** the audio‑recording permission (for the mixer). For headphone control,
pair your Sony headphones in **System Settings → Bluetooth**. Open the **Mixer** page, and flip
**Volume control** on to get the per‑app faders.

## Status
- Headphone control and per‑app **metering**: stable.
- Per‑app **volume control**: working and **opt‑in (experimental)**. Known limitation: an app you
  start *after* turning volume control on joins the mix only after you toggle volume control off
  and on again.

---

## Credits & license

The Sony headphone‑control foundation is the excellent open‑source project
**[open‑sound‑connect](https://github.com/rolottr/open-sound-connect)** by *rolottr and
contributors*. This project builds on it and adds the **per‑app audio Mixer** and the combined
Sound‑Connect‑plus‑mixer experience. Huge thanks to the upstream authors. The original upstream
README is preserved as [`README-upstream.md`](README-upstream.md).

Licensed under the **MIT License** (© rolottr and Sound Connect contributors — see
[`LICENSE`](LICENSE)). Mixer additions are released under the same MIT license.

**Not affiliated with or endorsed by Sony.** “Sony,” “Sound Connect,” and “WH‑1000XM” are
trademarks of Sony Group Corporation, used here only to describe compatibility.
