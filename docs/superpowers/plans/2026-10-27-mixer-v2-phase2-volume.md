# Mixer v2 — Phase 2: Per-App Volume Control — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in per-app volume control to the Mixer: a master toggle, 0–100% faders per app (remembered), backed by a muting-tap audio mixer with a hard bypass that always restores normal audio.

**Architecture:** The existing `ProcessTapEngine` gains a second mode. OFF (default) = today's non-muting metering (nothing in the playback path). ON = one muting aggregate device (all app taps as input + the real output device as output) whose single render callback applies each app's gain, mixes, and plays to the real device — while still computing pre-gain levels for the meters. `MixerModel` groups volumes per app, persists them (`VolumeStore`), and pushes per-pid gains down. Any failure or toggle-off tears the mixer down → normal audio. All non-Core-Audio logic is unit-tested behind the `AudioTapProviding` seam; the engine mixing is verified on-device.

**Tech Stack:** Swift 6 (lang mode 5), SwiftUI + Observation, Core Audio process taps + aggregate devices (macOS 14.4+), swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-27-mixer-volume-control-design.md` (volume-control portions; identification shipped in Phase 1).

**Build:** `./scripts/build.sh` · **Test:** `./scripts/test.sh [--filter NAME]`. **Branch:** `feature/mixer-volume-p2`.

**Reference for the mixer engine (Task 4):** Apple's process-tap sample [insidegui/AudioCap](https://github.com/insidegui/AudioCap) — adapt its muting-tap + aggregate-device-with-output pattern.

---

## File Structure

**Create:**
- `Sources/SoundConnect/Mixer/VolumeStore.swift` — persist per-app volumes + master toggle.

**Modify:**
- `Sources/SoundConnect/Mixer/MixerTypes.swift` — add `MixerEngineStatus`.
- `Sources/SoundConnect/Mixer/AppIdentity.swift` — add `volume` to `MixerRow`.
- `Sources/SoundConnect/Mixer/AudioTapProviding.swift` — add status + gain + enable members.
- `Sources/SoundConnect/Mixer/ProcessTapEngine.swift` — stub the new members (Task 1), then implement mixing mode (Task 4).
- `Sources/SoundConnect/Mixer/MixerModel.swift` — volume/toggle/status/persistence + gain fan-out.
- `Sources/SoundConnect/UI/MixerView.swift` — master toggle, sliders, bypass banner.
- `Tests/SoundConnectTests/MixerTests.swift` — extend `FakeTapProvider`; add store/model tests.

---

## Task 1: Types, protocol surface, and engine stubs

Adds the new API surface so later tasks compile. The engine members are stubs here (metering unchanged); Task 4 gives them real behavior.

**Files:**
- Modify: `Sources/SoundConnect/Mixer/MixerTypes.swift`
- Modify: `Sources/SoundConnect/Mixer/AppIdentity.swift`
- Modify: `Sources/SoundConnect/Mixer/AudioTapProviding.swift`
- Modify: `Sources/SoundConnect/Mixer/ProcessTapEngine.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift` (extend `FakeTapProvider`)

- [ ] **Step 1: Add `MixerEngineStatus` to `MixerTypes.swift`**

Append to `Sources/SoundConnect/Mixer/MixerTypes.swift`:

```swift
/// Engine mode / health, surfaced to the UI (a banner when bypassed).
enum MixerEngineStatus: Equatable {
    case metering                  // non-muting; not in the playback path
    case mixing                    // muting volume-mixer active
    case bypassed(reason: String)  // a failure or toggle-off restored normal audio
}
```

- [ ] **Step 2: Add `volume` to `MixerRow`**

In `Sources/SoundConnect/Mixer/AppIdentity.swift`, add a `volume` field to `MixerRow` (default keeps Phase 1 construction compiling):

```swift
struct MixerRow: Identifiable, Equatable {
    let id: String          // == AppIdentity.key
    let displayName: String
    let kind: AppIdentity.Kind
    var level: Float        // 0...1, combined (max) across member processes
    var isPlaying: Bool     // true if any member is currently producing audio
    var pids: [pid_t]       // member processes (sorted)
    var volume: Float = 1.0 // 0...1 user-set output level (100% = normal)
}
```

- [ ] **Step 3: Extend the `AudioTapProviding` protocol**

In `Sources/SoundConnect/Mixer/AudioTapProviding.swift`, add these members inside the protocol:

```swift
    /// Current engine status.
    var status: MixerEngineStatus { get }
    /// Called when the engine status changes.
    var onStatusChange: ((MixerEngineStatus) -> Void)? { get set }

    /// Enable/disable the muting volume-mixer. Off = metering only (never in the playback path).
    func setVolumeControlEnabled(_ enabled: Bool)
    /// Per-process output gains (0...1). Applied while mixing; retained for when mixing starts.
    func setGains(_ gains: [pid_t: Float])
```

- [ ] **Step 4: Stub the new members on `ProcessTapEngine`**

In `Sources/SoundConnect/Mixer/ProcessTapEngine.swift`, add these stored members near `onReadings`/`permission` (keep existing members):

```swift
    var onStatusChange: ((MixerEngineStatus) -> Void)?
    private(set) var status: MixerEngineStatus = .metering {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }
    private var volumeControlEnabled = false
    private var pendingGains: [pid_t: Float] = [:]
```

And add these methods (Task 4 replaces their bodies with real behavior):

```swift
    func setVolumeControlEnabled(_ enabled: Bool) {
        volumeControlEnabled = enabled
        // Task 4: switch between metering and mixing modes here.
    }

    func setGains(_ gains: [pid_t: Float]) {
        pendingGains = gains
        // Task 4: the render loop reads these to attenuate each app.
    }
```

- [ ] **Step 5: Extend `FakeTapProvider` in the tests**

In `Tests/SoundConnectTests/MixerTests.swift`, replace the existing `FakeTapProvider` class with:

```swift
/// Test double: lets a test push readings/permission/status and capture control calls.
@MainActor
final class FakeTapProvider: AudioTapProviding {
    var onReadings: (([TapReading]) -> Void)?
    var onPermissionChange: ((TapPermission) -> Void)?
    var onStatusChange: ((MixerEngineStatus) -> Void)?
    private(set) var permission: TapPermission = .unknown
    private(set) var status: MixerEngineStatus = .metering
    private(set) var started = false
    private(set) var enabledCalls: [Bool] = []
    private(set) var lastGains: [pid_t: Float] = [:]

    func start() { started = true }
    func stop() { started = false }
    func requestPermission() {}
    func setVolumeControlEnabled(_ enabled: Bool) { enabledCalls.append(enabled) }
    func setGains(_ gains: [pid_t: Float]) { lastGains = gains }

    func emit(_ readings: [TapReading]) { onReadings?(readings) }
    func setPermission(_ p: TapPermission) { permission = p; onPermissionChange?(p) }
    func emitStatus(_ s: MixerEngineStatus) { status = s; onStatusChange?(s) }
}
```

- [ ] **Step 6: Build + full suite**

Run: `./scripts/build.sh` → `Built ...`.
Run: `./scripts/test.sh` → all pass (35; nothing new asserted yet, but the extended fake + types must compile and existing tests stay green).

- [ ] **Step 7: Commit**

```bash
git add Sources/SoundConnect/Mixer/MixerTypes.swift Sources/SoundConnect/Mixer/AppIdentity.swift Sources/SoundConnect/Mixer/AudioTapProviding.swift Sources/SoundConnect/Mixer/ProcessTapEngine.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add volume-control API surface (status, gains, enable) + engine stubs"
```

---

## Task 2: Volume persistence store

**Files:**
- Create: `Sources/SoundConnect/Mixer/VolumeStore.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SoundConnectTests/MixerTests.swift`:

```swift
struct VolumeStoreTests {
    private func store() -> VolumeStore {
        VolumeStore(defaults: UserDefaults(suiteName: "mixer-test-\(UUID().uuidString)")!)
    }

    @Test func roundTripsStableKeys() {
        let s = store()
        #expect(s.volume(forKey: "com.spotify.client") == nil)   // absent -> nil
        s.setVolume(0.4, forKey: "com.spotify.client")
        #expect(s.volume(forKey: "com.spotify.client") == 0.4)
    }

    @Test func doesNotPersistEphemeralPidKeys() {
        let s = store()
        s.setVolume(0.3, forKey: "pid:1234")
        #expect(s.volume(forKey: "pid:1234") == nil)             // never stored
    }

    @Test func persistsDaemonKeys() {
        let s = store()
        s.setVolume(0.5, forKey: "daemon:avconferenced")
        #expect(s.volume(forKey: "daemon:avconferenced") == 0.5)
    }

    @Test func masterToggleDefaultsOffAndRoundTrips() {
        let s = store()
        #expect(s.isVolumeControlEnabled == false)
        s.isVolumeControlEnabled = true
        #expect(s.isVolumeControlEnabled == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter VolumeStoreTests`
Expected: FAIL — `cannot find 'VolumeStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SoundConnect/Mixer/VolumeStore.swift`:

```swift
import Foundation

/// Persists per-app volumes and the master toggle in `UserDefaults`. Only *stable* identities
/// (app bundle ids, daemon labels) are persisted; ephemeral "pid:" rows are session-only.
struct VolumeStore {
    private let defaults: UserDefaults
    private static let volumesKey = "mixerVolumes"
    private static let enabledKey = "mixerVolumeControlEnabled"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A key is stable (persistable) unless it is an ephemeral "pid:<pid>" identity.
    static func isStable(_ key: String) -> Bool { !key.hasPrefix("pid:") }

    func volume(forKey key: String) -> Float? {
        guard Self.isStable(key),
              let dict = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double],
              let value = dict[key] else { return nil }
        return Float(value)
    }

    func setVolume(_ value: Float, forKey key: String) {
        guard Self.isStable(key) else { return }
        var dict = (defaults.dictionary(forKey: Self.volumesKey) as? [String: Double]) ?? [:]
        dict[key] = Double(value)
        defaults.set(dict, forKey: Self.volumesKey)
    }

    var isVolumeControlEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }          // defaults to false
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter VolumeStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/Mixer/VolumeStore.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add VolumeStore (per-app volumes + master toggle persistence)"
```

---

## Task 3: Model volume, toggle, persistence, and gain fan-out

**Files:**
- Modify: `Sources/SoundConnect/Mixer/MixerModel.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift` (append a new test struct)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SoundConnectTests/MixerTests.swift`:

```swift
@MainActor
struct MixerVolumeTests {
    private func store() -> VolumeStore {
        VolumeStore(defaults: UserDefaults(suiteName: "mixer-vol-\(UUID().uuidString)")!)
    }
    /// Model whose resolver maps each pid to app "k<pid>" (stable bundle-id identity).
    private func model(_ fake: FakeTapProvider, _ s: VolumeStore) -> MixerModel {
        MixerModel(provider: fake, store: s) { pid in
            AppIdentity(key: "k\(pid)", displayName: "App\(pid)", kind: .app(bundleID: "k\(pid)"))
        }
    }

    @Test func togglePersistsAndForwardsToProvider() {
        let fake = FakeTapProvider(); let s = store()
        let m = model(fake, s)
        m.setVolumeControlEnabled(true)
        #expect(m.volumeControlEnabled)
        #expect(s.isVolumeControlEnabled)
        #expect(fake.enabledCalls.last == true)
    }

    @Test func restoresToggleStateOnInit() {
        let fake = FakeTapProvider(); let s = store()
        s.isVolumeControlEnabled = true
        let m = model(fake, s)
        #expect(m.volumeControlEnabled)
    }

    @Test func setVolumeUpdatesRowPersistsAndPushesGains() {
        let fake = FakeTapProvider(); let s = store()
        let m = model(fake, s)
        fake.emit([TapReading(pid: 42, bundleID: nil, level: 1)])
        m.setVolume(0.4, forRow: "k42")
        #expect(m.apps[0].volume == 0.4)
        #expect(s.volume(forKey: "k42") == 0.4)
        #expect(fake.lastGains[42] == 0.4)
    }

    @Test func volumeFansOutToAllMemberPids() {
        let fake = FakeTapProvider(); let s = store()
        let m = MixerModel(provider: fake, store: s) { _ in
            AppIdentity(key: "shared", displayName: "Shared", kind: .app(bundleID: "shared"))
        }
        fake.emit([TapReading(pid: 1, bundleID: nil, level: 1), TapReading(pid: 2, bundleID: nil, level: 1)])
        m.setVolume(0.25, forRow: "shared")
        #expect(fake.lastGains[1] == 0.25)
        #expect(fake.lastGains[2] == 0.25)
    }

    @Test func appliesSavedVolumeWhenRowAppears() {
        let fake = FakeTapProvider(); let s = store()
        s.setVolume(0.3, forKey: "k42")
        let m = model(fake, s)
        fake.emit([TapReading(pid: 42, bundleID: nil, level: 1)])
        #expect(m.apps[0].volume == 0.3)
        #expect(fake.lastGains[42] == 0.3)
    }

    @Test func ephemeralRowIsAdjustableButNotPersisted() {
        let fake = FakeTapProvider(); let s = store()
        let m = MixerModel(provider: fake, store: s) { pid in
            AppIdentity(key: "pid:\(pid)", displayName: "PID \(pid)", kind: .unknown)
        }
        fake.emit([TapReading(pid: 9, bundleID: nil, level: 1)])
        m.setVolume(0.5, forRow: "pid:9")
        #expect(m.apps[0].volume == 0.5)          // adjustable this session
        #expect(fake.lastGains[9] == 0.5)
        #expect(s.volume(forKey: "pid:9") == nil) // not persisted
    }

    @Test func statusChangesPropagate() {
        let fake = FakeTapProvider(); let s = store()
        let m = model(fake, s)
        #expect(m.status == .metering)
        fake.emitStatus(.bypassed(reason: "test"))
        #expect(m.status == .bypassed(reason: "test"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter MixerVolumeTests`
Expected: FAIL — `MixerModel` has no `store:` init param / `volumeControlEnabled` / `setVolume`.

- [ ] **Step 3: Replace `MixerModel.swift`**

Replace the ENTIRE contents of `Sources/SoundConnect/Mixer/MixerModel.swift` with:

```swift
import AppKit

/// Observable state for the Mixer page. Owns an `AudioTapProviding`, smooths per-process levels,
/// resolves each process to an app identity, groups them into `[MixerRow]` (one per app), and
/// manages per-app volume + the master toggle (persisted via `VolumeStore`). Pure of Core Audio.
@MainActor
@Observable
final class MixerModel {
    private(set) var apps: [MixerRow] = []
    private(set) var permission: TapPermission = .unknown
    private(set) var volumeControlEnabled: Bool
    private(set) var status: MixerEngineStatus = .metering

    private let provider: any AudioTapProviding
    private let resolve: @MainActor (pid_t) -> AppIdentity
    private let store: VolumeStore

    private var order: [pid_t] = []
    private var smoothers: [pid_t: LevelSmoother] = [:]
    private var identities: [pid_t: AppIdentity] = [:]
    private var volumes: [String: Float] = [:]      // identity key -> live volume
    private var lastGains: [pid_t: Float] = [:]

    private let removalThreshold: Float = 0.01

    init(provider: any AudioTapProviding,
         store: VolumeStore = VolumeStore(),
         resolver: @escaping @MainActor (pid_t) -> AppIdentity) {
        self.provider = provider
        self.store = store
        self.resolve = resolver
        self.permission = provider.permission
        self.status = provider.status
        self.volumeControlEnabled = store.isVolumeControlEnabled
        provider.onReadings = { [weak self] readings in self?.ingest(readings) }
        provider.onPermissionChange = { [weak self] p in self?.permission = p }
        provider.onStatusChange = { [weak self] s in self?.status = s }
    }

    /// Production convenience: real Core Audio engine + real app-identity resolver.
    convenience init() {
        let resolver = AppIdentityResolver.live()
        self.init(provider: ProcessTapEngine()) { resolver.identity(forPID: $0) }
    }

    func start() {
        provider.start()
        provider.setVolumeControlEnabled(volumeControlEnabled)
    }
    func stop() { provider.stop() }
    func requestPermission() { provider.requestPermission() }

    func setVolumeControlEnabled(_ on: Bool) {
        volumeControlEnabled = on
        store.isVolumeControlEnabled = on
        provider.setVolumeControlEnabled(on)
    }

    func setVolume(_ value: Float, forRow id: String) {
        let v = min(1, max(0, value))
        volumes[id] = v
        store.setVolume(v, forKey: id)
        if let i = apps.firstIndex(where: { $0.id == id }) { apps[i].volume = v }
        pushGains()
    }

    private func ingest(_ readings: [TapReading]) {
        let present = Set(readings.map(\.pid))

        for r in readings where identities[r.pid] == nil {
            identities[r.pid] = resolve(r.pid)
        }

        let fading = order.filter { !present.contains($0) }
        let working = MixerReconciler.order(previous: order, current: present.union(fading))
        let targets = Dictionary(readings.map { ($0.pid, $0.level) }, uniquingKeysWith: { a, _ in a })

        var entries: [MixerGrouping.Entry] = []
        var nextOrder: [pid_t] = []

        for pid in working {
            let target = targets[pid] ?? 0
            var smoother = smoothers[pid] ?? LevelSmoother()
            let level = smoother.update(target: target)

            let playing = present.contains(pid)
            if !playing && level < removalThreshold {
                smoothers[pid] = nil
                identities[pid] = nil
                continue
            }
            smoothers[pid] = smoother
            nextOrder.append(pid)
            let identity = identities[pid] ?? AppIdentity(key: "pid:\(pid)", displayName: "PID \(pid)", kind: .unknown)
            entries.append(MixerGrouping.Entry(pid: pid, level: level, isPlaying: playing, identity: identity))
        }

        order = nextOrder
        var rows = MixerGrouping.rows(from: entries)
        for i in rows.indices {
            let key = rows[i].id
            if volumes[key] == nil { volumes[key] = store.volume(forKey: key) ?? 1.0 }
            rows[i].volume = volumes[key] ?? 1.0
        }
        apps = rows
        pushGains()
    }

    /// Fan each row's volume out to its member pids; push to the engine only when it changes.
    private func pushGains() {
        var map: [pid_t: Float] = [:]
        for row in apps { for pid in row.pids { map[pid] = row.volume } }
        if map != lastGains {
            lastGains = map
            provider.setGains(map)
        }
    }
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `./scripts/test.sh --filter MixerVolumeTests` → PASS (7 tests).
Run: `./scripts/test.sh` → all pass (46). Run `./scripts/build.sh` → `Built ...`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/Mixer/MixerModel.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): model per-app volume, master toggle, persistence, gain fan-out"
```

---

## Task 4: Mixing-mode engine (muting mixer + gain + bypass) — on-device

Implements the real volume mixer in `ProcessTapEngine`. It cannot be unit-tested (needs real audio + the aggregate device); it is verified on-device in Task 5. **Adapt the muting-tap + aggregate-with-output pattern from AudioCap.**

**Files:**
- Modify: `Sources/SoundConnect/Mixer/ProcessTapEngine.swift`

- [ ] **Step 1: Add a thread-safe gain store**

Add near the top of the file (next to `LevelStore`):

```swift
/// Per-pid output gains read by the mixing render callback. Lock-guarded; no allocation in audio thread.
private final class GainStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [pid_t: Float] = [:]
    func set(_ g: [pid_t: Float]) { lock.lock(); values = g; lock.unlock() }
    func gain(_ pid: pid_t) -> Float { lock.lock(); defer { lock.unlock() }; return values[pid] ?? 1 }
}
```

Add a `private let gains = GainStore()` property, and make `setGains` store there:

```swift
    func setGains(_ gains: [pid_t: Float]) { self.gains.set(gains) }
```

- [ ] **Step 2: Implement mode switching in `setVolumeControlEnabled`**

Replace the Task-1 stub with:

```swift
    func setVolumeControlEnabled(_ enabled: Bool) {
        guard enabled != volumeControlEnabled else { return }
        volumeControlEnabled = enabled
        guard publishTimer != nil, permission == .granted else { return }  // not running yet
        rebuild()   // rebuild in the new mode
    }
```

- [ ] **Step 3: Make `rebuild()` branch on mode, and add the mixing builder + bypass**

Change `rebuild()` to:

```swift
    private func rebuild() {
        teardown()
        if volumeControlEnabled {
            if buildMixer() { status = .mixing } else { bypass("Could not start the volume mixer") }
        } else {
            for process in runningOutputProcesses() {
                if let handle = makeTap(for: process) { handles.append(handle) }
            }
            status = .metering
        }
    }

    /// Tear the mixer down and fall back to metering so audio is never left muted.
    private func bypass(_ reason: String) {
        teardown()
        for process in runningOutputProcesses() {
            if let handle = makeTap(for: process) { handles.append(handle) }
        }
        volumeControlEnabled = false
        status = .bypassed(reason: reason)
    }
```

- [ ] **Step 4: Implement `buildMixer()`**

Add this method. It builds muting taps for the current output processes and ONE aggregate device containing those taps plus the current default output device, with a render callback that applies gain, mixes, and writes to the output — while storing pre-gain RMS for the meters. **This is the part to adapt carefully from AudioCap; iterate on-device until audio adjusts correctly.**

```swift
    /// Returns true if the muting mixer started. On any failure returns false (caller bypasses).
    private func buildMixer() -> Bool {
        let processes = runningOutputProcesses()
        guard !processes.isEmpty else { return true }   // nothing to mix yet; mixing becomes active on next rebuild

        // 1. One muting tap per process (mutes the app at the real device, routes audio to us).
        var subTapUIDs: [String] = []
        for process in processes {
            let desc = CATapDescription(stereoMixdownOfProcesses: [process.object])
            desc.isPrivate = true
            desc.muteBehavior = .mutedWhenTapped
            desc.name = "SoundConnectMix-\(process.pid)"
            var tapID = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != kAudioObjectUnknown else {
                log.error("mixer: tap failed for pid \(process.pid)"); return false
            }
            // Reuse TapHandle to track the tap for teardown (aggregate/ioProc set below on the shared device).
            handles.append(TapHandle(pid: process.pid, tapID: tapID, aggregateID: 0, ioProcID: nil))
            subTapUIDs.append(desc.uuid.uuidString)
        }

        // 2. The current default output device (where the mixed audio must play).
        guard let outputUID = defaultOutputDeviceUID() else { return false }

        // 3. One private aggregate: the muting taps as input + the real output device as output.
        let aggUID = UUID().uuidString
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SoundConnectMixer",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outputUID]],
            kAudioAggregateDeviceTapListKey as String: subTapUIDs.map {
                [kAudioSubTapUIDKey as String: $0, kAudioSubTapDriftCompensationKey as String: true]
            },
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]
        var aggID = AudioDeviceID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID) == noErr,
              aggID != kAudioObjectUnknown else {
            log.error("mixer: aggregate create failed"); return false
        }
        mixerAggregateID = aggID

        // 4. Render callback: apply each app's gain, mix the taps, write to the output; store pre-gain RMS.
        let gains = self.gains
        let store = self.store
        let pids = processes.map(\.pid)
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            Self.renderMix(input: inInputData, output: outOutputData, pids: pids, gains: gains, levels: store)
        }
        var ioProcID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, ioQueue, ioBlock) == noErr, let ioProcID else {
            log.error("mixer: io proc failed"); return false
        }
        mixerIOProcID = ioProcID
        guard AudioDeviceStart(aggID, ioProcID) == noErr else { log.error("mixer: start failed"); return false }
        return true
    }
```

Add the two helper members and the output-UID + render helpers:

```swift
    private var mixerAggregateID: AudioDeviceID = 0
    private var mixerIOProcID: AudioDeviceIOProcID?

    private func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?; var usz = UInt32(MemoryLayout<CFString?>.size)
        guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &usz, $0) }) == noErr,
              let s = uid?.takeRetainedValue() as String? else { return nil }
        return s
    }

    /// Audio thread: copy each tap's input to the matching output channels scaled by the app's gain,
    /// and store pre-gain RMS per pid for the meters. No allocation / no locks beyond the stores.
    private static func renderMix(input: UnsafePointer<AudioBufferList>,
                                  output: UnsafeMutablePointer<AudioBufferList>,
                                  pids: [pid_t], gains: GainStore, levels: LevelStore) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)
        // Zero the output first.
        for ob in outBuffers { if let d = ob.mData { memset(d, 0, Int(ob.mDataByteSize)) } }
        // Each input buffer corresponds (in tap-list order) to a tapped process.
        for (i, ib) in inBuffers.enumerated() {
            guard let inData = ib.mData, i < pids.count else { continue }
            let frames = Int(ib.mDataByteSize) / MemoryLayout<Float>.size
            let inSamples = inData.assumingMemoryBound(to: Float.self)
            // pre-gain RMS for the meter
            var sum: Float = 0
            for f in 0..<frames { sum += inSamples[f] * inSamples[f] }
            levels.set(pids[i], bundleID: nil, level: frames > 0 ? min(1, (sum / Float(frames)).squareRoot()) : 0)
            // mix into the (single) output buffer scaled by gain
            let g = gains.gain(pids[i])
            if let ob = outBuffers.first, let outData = ob.mData {
                let outSamples = outData.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(ob.mDataByteSize) / MemoryLayout<Float>.size)
                for f in 0..<n { outSamples[f] += inSamples[f] * g }
            }
        }
    }
```

Finally, update `teardown()` to also tear down the mixer device/proc (in addition to the existing per-handle taps):

```swift
    private func teardown() {
        if let ioProcID = mixerIOProcID, mixerAggregateID != 0 {
            AudioDeviceStop(mixerAggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(mixerAggregateID, ioProcID)
        }
        if mixerAggregateID != 0 { AudioHardwareDestroyAggregateDevice(mixerAggregateID) }
        mixerAggregateID = 0; mixerIOProcID = nil
        for handle in handles {
            if let ioProcID = handle.ioProcID, handle.aggregateID != 0 {
                AudioDeviceStop(handle.aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(handle.aggregateID, ioProcID)
            }
            if handle.aggregateID != 0 { AudioHardwareDestroyAggregateDevice(handle.aggregateID) }
            AudioHardwareDestroyProcessTap(handle.tapID)
        }
        handles.removeAll()
    }
```

- [ ] **Step 2 (verify build + no test regression)**

Run: `./scripts/build.sh` → `Built ...` (resolve any Core Audio compile errors against AudioCap).
Run: `./scripts/test.sh` → all still pass (the model/store tests use the fake; the engine isn't exercised in unit tests).

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundConnect/Mixer/ProcessTapEngine.swift
git commit -m "feat(mixer): muting mixer mode with per-app gain and hard bypass"
```

> Runtime correctness (does dragging actually change what you hear; does toggle-off/any failure instantly restore normal audio with no stuck-muted app) is verified in Task 5 on-device, iterating on this render/aggregate code as needed.

---

## Task 5: UI — master toggle, sliders, bypass banner (+ on-device verification)

**Files:**
- Modify: `Sources/SoundConnect/UI/MixerView.swift`

- [ ] **Step 1: Add the master toggle to the header**

In `MixerView.body`, replace the subtitle `Text("Live level for each app playing audio.")` block with a header row that includes the toggle:

```swift
            HStack(alignment: .firstTextBaseline) {
                Text(mixer.volumeControlEnabled ? "Drag to set how much of each app you hear." : "Live level for each app playing audio.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                Spacer()
                Toggle("Volume control", isOn: Binding(
                    get: { mixer.volumeControlEnabled },
                    set: { mixer.setVolumeControlEnabled($0) }))
                    .toggleStyle(.switch).tint(Theme.accent)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 28).padding(.bottom, 18)
```

And directly under that, a bypass banner:

```swift
            if case let .bypassed(reason) = mixer.status {
                Text("Volume control paused — audio restored to normal. (\(reason))")
                    .font(.caption).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 28).padding(.bottom, 10)
            }
```

- [ ] **Step 2: Give `AppRowView` a slider when volume control is on**

Replace `AppRowView` with a version that shows a slider when enabled. It needs the model to call `setVolume`:

```swift
private struct AppRowView: View {
    @Environment(MixerModel.self) private var mixer
    let app: MixerRow

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(kind: app.kind, pids: app.pids)
                .frame(width: 26, height: 26)

            Text(app.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            if mixer.volumeControlEnabled {
                Slider(value: Binding(
                    get: { Double(app.volume) },
                    set: { mixer.setVolume(Float($0), forRow: app.id) }),
                    in: 0...1)
                    .controlSize(.small).tint(Theme.accent)
                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary).frame(width: 40, alignment: .trailing)
                Meter(level: app.level).frame(width: 60, height: 6).opacity(app.isPlaying ? 1 : 0.4)
            } else {
                Meter(level: app.level).frame(height: 10).opacity(app.isPlaying ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.displayName)\(mixer.volumeControlEnabled ? ", volume \(Int(app.volume * 100)) percent" : ", level \(Int(app.level * 100)) percent")")
    }
}
```

- [ ] **Step 3: Build**

Run: `./scripts/build.sh` → `Built ...`. If `Theme.warning` doesn't exist, use `Theme.secondary`.

- [ ] **Step 4: On-device verification (the real test — iterate on Task 4 if needed)**

Run: `osascript -e 'quit app "Sound Connect"'; open "build/Sound Connect.app"`. With a few apps playing:
- Toggle **Volume control ON** → each row shows a **slider + %** and a small live meter.
- Drag **Brave Browser** (or Spotify) **down** → only that app gets quieter; others unchanged. 0% = silent.
- **Audio stays clean** (no distortion/crackle) while mixing.
- Toggle **OFF** → audio instantly returns to full/normal (no app left muted).
- **Quit & relaunch** → a level you set on a real app (e.g. Spotify 40%) is remembered; toggle state remembered.
- Switch output device (speakers ↔ XM5) while ON → audio continues (engine rebuilds); if it drops, it should bypass (banner) not go silent.
- If anything misbehaves (distortion, wrong channel mix, a stuck-muted app), that's Task 4 render/aggregate code to iterate on.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/UI/MixerView.swift
git commit -m "feat(mixer): master toggle, per-app volume sliders, bypass banner"
```

---

## Self-Review

**Spec coverage (volume portions):**
- 0–100% fader per app, 100% = normal → `MixerRow.volume` + Slider (T1/T5); model clamps (T3). ✅
- Opt-in master toggle, OFF default, remembered → `VolumeStore.isVolumeControlEnabled` (T2), model (T3), Toggle (T5). ✅
- Muting-tap + single aggregate (taps + real output) mixer with per-app gain → T4. ✅
- Pre-gain meters while mixing → `renderMix` stores RMS (T4). ✅
- Hard bypass always unmutes (teardown destroys taps; bypass rebuilds metering) → T4 `bypass()`/`teardown()`. ✅
- Per-app persistence, stable identities only → `VolumeStore` + model apply-on-appear (T2/T3). ✅
- Status/bypass banner → `MixerEngineStatus` (T1), model (T3), banner (T5). ✅
- Default-output change handled → T4/T5 note (rebuild; bypass if it fails). ✅

**Placeholder scan:** The only deferred bodies are Task 1's engine stubs, explicitly filled in Task 4; every step shows complete code. No "TBD/handle errors" prose.

**Type consistency:** `MixerEngineStatus.{metering,mixing,bypassed(reason:)}`, `MixerRow.volume`, `AudioTapProviding.{status,onStatusChange,setVolumeControlEnabled(_:),setGains(_:)}`, `VolumeStore(defaults:)`/`.volume(forKey:)`/`.setVolume(_:forKey:)`/`.isVolumeControlEnabled`/`.isStable(_:)`, `MixerModel(provider:store:resolver:)`/`volumeControlEnabled`/`status`/`setVolumeControlEnabled(_:)`/`setVolume(_:forRow:)`, and the engine's `GainStore`/`buildMixer()`/`bypass(_:)`/`renderMix(...)` are used consistently across tasks.
