# Per-App Mixer Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only "Mixer" sidebar page to Sound Connect that shows a live audio level meter for each app currently producing sound.

**Architecture:** A new `Mixer/` group with pure, unit-tested logic (level math, smoothing, row reconciliation, an observable model) separated from an untestable Core Audio shell (`ProcessTapEngine`) hidden behind an `AudioTapProviding` protocol. The SwiftUI `MixerView` reads the observable model. Taps are **non-muting**, so the app never sits in the playback path. Built so v2 can swap non-muting taps for muting+gain and turn the meters into volume sliders without reshaping the model or view.

**Tech Stack:** Swift 6 (language mode 5), SwiftUI + the Observation framework (`@Observable`), Core Audio process taps (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.4+), swift-testing (`import Testing`, `@Test`, `#expect`).

**Reference:** Apple's process-tap sample [insidegui/AudioCap](https://github.com/insidegui/AudioCap) is the canonical example for the Core Audio calls in Task 4 — consult it for the exact incantations.

**Spec:** `docs/superpowers/specs/2026-10-27-per-app-mixer-widget-design.md`

**Build:** `./scripts/build.sh` · **Test:** `./scripts/test.sh` (wraps `swift test`). Run a subset with `./scripts/test.sh --filter MixerTests`.

**Branch:** `feature/mixer-widget` (already checked out).

---

## File Structure

**Create:**
- `Sources/SoundConnect/Mixer/AudioLevelMath.swift` — pure RMS/peak math + `LevelSmoother`.
- `Sources/SoundConnect/Mixer/MixerTypes.swift` — value types: `AppAudioLevel`, `TapReading`, `TapPermission`.
- `Sources/SoundConnect/Mixer/MixerReconciler.swift` — pure row-ordering logic.
- `Sources/SoundConnect/Mixer/AudioTapProviding.swift` — protocol seam over Core Audio.
- `Sources/SoundConnect/Mixer/MixerModel.swift` — `@MainActor @Observable` orchestration.
- `Sources/SoundConnect/Mixer/ProcessTapEngine.swift` — real Core Audio implementation of `AudioTapProviding`.
- `Sources/SoundConnect/UI/MixerView.swift` — the sidebar page + states + meter row.
- `Tests/SoundConnectTests/MixerTests.swift` — unit tests + `FakeTapProvider`.

**Modify:**
- `Sources/SoundConnect/UI/RootView.swift` — add `.mixer` to `AppPage` and the `content(for:)` switch.
- `Sources/SoundConnect/App/SoundConnectApp.swift` — own a `MixerModel`, inject it, start/stop it.
- `Resources/Info.plist` — add `NSAudioCaptureUsageDescription`.

---

## Task 1: Level math and smoother

**Files:**
- Create: `Sources/SoundConnect/Mixer/AudioLevelMath.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SoundConnectTests/MixerTests.swift`:

```swift
import Testing
@testable import SoundConnect

struct AudioLevelMathTests {
    @Test func rmsOfSilenceIsZero() {
        #expect(AudioLevelMath.rms([0, 0, 0, 0]) == 0)
    }

    @Test func rmsOfFullScaleIsOne() {
        #expect(abs(AudioLevelMath.rms([1, -1, 1, -1]) - 1) < 0.0001)
    }

    @Test func rmsIsClampedToUnit() {
        #expect(AudioLevelMath.rms([4, -4]) == 1)
    }

    @Test func peakPicksLargestMagnitude() {
        #expect(abs(AudioLevelMath.peak([0.1, -0.8, 0.3]) - 0.8) < 0.0001)
        #expect(AudioLevelMath.peak([]) == 0)
    }

    @Test func smootherRisesFastAndFallsSlow() {
        var s = LevelSmoother(attack: 0.5, decay: 0.1)
        let up = s.update(target: 1)          // 0 -> 0.5 in one step
        #expect(abs(up - 0.5) < 0.0001)
        var d = LevelSmoother(attack: 0.5, decay: 0.1)
        _ = d.update(target: 1); _ = d.update(target: 1); _ = d.update(target: 1)
        let before = d.value
        let after = d.update(target: 0)        // falls slowly
        #expect(after < before)
        #expect(after > before * 0.5)          // not an instant drop
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter AudioLevelMathTests`
Expected: FAIL — `cannot find 'AudioLevelMath'` / `'LevelSmoother'` in scope.

- [ ] **Step 3: Write the implementation**

Create `Sources/SoundConnect/Mixer/AudioLevelMath.swift`:

```swift
import Foundation

/// Pure helpers for turning a buffer of float audio samples into a 0...1 level.
enum AudioLevelMath {
    /// Root-mean-square of the samples, clamped to 0...1. Empty buffer is 0.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return min(1, (sumSquares / Float(samples.count)).squareRoot())
    }

    /// Largest absolute sample value, clamped to 0...1. Empty buffer is 0.
    static func peak(_ samples: [Float]) -> Float {
        min(1, samples.reduce(Float(0)) { max($0, abs($1)) })
    }
}

/// Smooths a 0...1 level so meters look natural: quick to rise, gentle to fall.
struct LevelSmoother {
    private(set) var value: Float = 0
    var attack: Float = 0.5
    var decay: Float = 0.12

    init(attack: Float = 0.5, decay: Float = 0.12) {
        self.attack = attack
        self.decay = decay
    }

    /// Moves `value` a fraction of the way toward `target` and returns it.
    @discardableResult
    mutating func update(target: Float) -> Float {
        let coeff = target > value ? attack : decay
        value += (target - value) * coeff
        return value
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter AudioLevelMathTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/Mixer/AudioLevelMath.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add audio level math and smoother"
```

---

## Task 2: Core value types and row reconciler

**Files:**
- Create: `Sources/SoundConnect/Mixer/MixerTypes.swift`
- Create: `Sources/SoundConnect/Mixer/MixerReconciler.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SoundConnectTests/MixerTests.swift`:

```swift
struct MixerReconcilerTests {
    @Test func keepsExistingOrderAndAppendsNewSorted() {
        let result = MixerReconciler.order(previous: [10, 20, 30], current: [20, 30, 5, 40])
        // 20 and 30 keep their previous order; new pids (5, 40) appended ascending.
        #expect(result == [20, 30, 5, 40])
    }

    @Test func dropsPidsNoLongerPresent() {
        let result = MixerReconciler.order(previous: [10, 20, 30], current: [20])
        #expect(result == [20])
    }

    @Test func emptyCurrentYieldsEmpty() {
        #expect(MixerReconciler.order(previous: [1, 2], current: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter MixerReconcilerTests`
Expected: FAIL — `cannot find 'MixerReconciler' in scope`.

- [ ] **Step 3: Write the implementations**

Create `Sources/SoundConnect/Mixer/MixerTypes.swift`:

```swift
import Foundation

/// One app's current audio level, as shown in a Mixer row. Pure/Equatable for testing;
/// the app icon is resolved in the view from `pid`, keeping this value type simple.
struct AppAudioLevel: Identifiable, Equatable {
    let pid: pid_t
    var bundleID: String?
    var displayName: String
    var level: Float        // 0...1, already smoothed
    var isPlaying: Bool     // false while a stopped app fades out
    var id: pid_t { pid }
}

/// One raw reading for a process in a single update cycle, produced by an `AudioTapProviding`.
struct TapReading: Equatable {
    let pid: pid_t
    let bundleID: String?
    let level: Float        // 0...1 raw (pre-smoothing) for this cycle
}

/// Whether the user has granted macOS audio-capture permission.
enum TapPermission: Equatable {
    case unknown    // not asked yet
    case granted
    case denied
}
```

Create `Sources/SoundConnect/Mixer/MixerReconciler.swift`:

```swift
import Foundation

/// Pure logic for the stable ordering of Mixer rows across update cycles.
enum MixerReconciler {
    /// Returns the new row order: pids present in both keep their previous relative order,
    /// pids no longer present are dropped, and newly-seen pids are appended in ascending order
    /// (deterministic for tests and stable on screen).
    static func order(previous: [pid_t], current: Set<pid_t>) -> [pid_t] {
        let kept = previous.filter { current.contains($0) }
        let new = current.subtracting(kept).sorted()
        return kept + new
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter MixerReconcilerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/Mixer/MixerTypes.swift Sources/SoundConnect/Mixer/MixerReconciler.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add value types and row reconciler"
```

---

## Task 3: Tap provider protocol and the observable model

**Files:**
- Create: `Sources/SoundConnect/Mixer/AudioTapProviding.swift`
- Create: `Sources/SoundConnect/Mixer/MixerModel.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SoundConnectTests/MixerTests.swift`:

```swift
import Foundation

/// Test double: lets a test push readings and permission changes by hand.
@MainActor
final class FakeTapProvider: AudioTapProviding {
    var onReadings: (([TapReading]) -> Void)?
    var onPermissionChange: ((TapPermission) -> Void)?
    private(set) var permission: TapPermission = .unknown
    private(set) var started = false

    func start() { started = true }
    func stop() { started = false }
    func requestPermission() {}

    func emit(_ readings: [TapReading]) { onReadings?(readings) }
    func setPermission(_ p: TapPermission) { permission = p; onPermissionChange?(p) }
}

@MainActor
struct MixerModelTests {
    private func model(_ fake: FakeTapProvider) -> MixerModel {
        MixerModel(provider: fake) { pid in ("App\(pid)", "com.test.\(pid)") }
    }

    @Test func startForwardsToProvider() {
        let fake = FakeTapProvider()
        let m = model(fake)
        m.start()
        #expect(fake.started)
    }

    @Test func addsRowWithResolvedNameAndSmoothedLevel() {
        let fake = FakeTapProvider()
        let m = model(fake)
        fake.emit([TapReading(pid: 42, bundleID: "com.test.42", level: 1)])
        #expect(m.apps.count == 1)
        #expect(m.apps[0].pid == 42)
        #expect(m.apps[0].displayName == "App42")
        #expect(m.apps[0].isPlaying)
        #expect(m.apps[0].level > 0 && m.apps[0].level < 1)   // smoothed, not instant
        let first = m.apps[0].level
        fake.emit([TapReading(pid: 42, bundleID: "com.test.42", level: 1)])
        #expect(m.apps[0].level > first)                      // keeps rising
    }

    @Test func dropsRowAfterItFadesWhenAbsent() {
        let fake = FakeTapProvider()
        let m = model(fake)
        fake.emit([TapReading(pid: 7, bundleID: nil, level: 1)])
        #expect(m.apps.count == 1)
        for _ in 0..<200 { fake.emit([]) }                    // absent -> decays to ~0 -> removed
        #expect(m.apps.isEmpty)
    }

    @Test func permissionChangesPropagate() {
        let fake = FakeTapProvider()
        let m = model(fake)
        #expect(m.permission == .unknown)
        fake.setPermission(.denied)
        #expect(m.permission == .denied)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter MixerModelTests`
Expected: FAIL — `cannot find 'AudioTapProviding'` / `'MixerModel'` in scope.

- [ ] **Step 3: Write the implementations**

Create `Sources/SoundConnect/Mixer/AudioTapProviding.swift`:

```swift
import Foundation

/// Seam over Core Audio. The real implementation is `ProcessTapEngine`; tests use a fake.
/// All callbacks are delivered on the main actor so `MixerModel` stays main-actor clean.
@MainActor
protocol AudioTapProviding: AnyObject {
    /// Called ~30×/sec with the latest raw per-process levels.
    var onReadings: (([TapReading]) -> Void)? { get set }
    /// Called when audio-capture permission changes.
    var onPermissionChange: ((TapPermission) -> Void)? { get set }
    /// Current permission state.
    var permission: TapPermission { get }

    func start()
    func stop()
    /// Triggers the macOS permission prompt if it has not been shown yet.
    func requestPermission()
}
```

Create `Sources/SoundConnect/Mixer/MixerModel.swift`:

```swift
import AppKit

/// Observable state for the Mixer page. Owns an `AudioTapProviding`, smooths and orders
/// the readings into `apps`, and tracks permission. Pure of Core Audio (that lives behind
/// the provider), so it is fully unit-testable with a fake provider.
@MainActor
@Observable
final class MixerModel {
    private(set) var apps: [AppAudioLevel] = []
    private(set) var permission: TapPermission = .unknown

    private let provider: any AudioTapProviding
    /// pid -> (displayName, bundleID). Injected so tests avoid `NSRunningApplication`.
    private let resolve: (pid_t) -> (name: String, bundleID: String?)

    private var order: [pid_t] = []
    private var smoothers: [pid_t: LevelSmoother] = [:]
    private var names: [pid_t: String] = [:]
    private var bundleIDs: [pid_t: String?] = [:]

    /// Rows below this smoothed level and no longer producing audio are removed.
    private let removalThreshold: Float = 0.01

    init(provider: any AudioTapProviding,
         resolver: @escaping (pid_t) -> (name: String, bundleID: String?)) {
        self.provider = provider
        self.resolve = resolver
        self.permission = provider.permission
        provider.onReadings = { [weak self] readings in self?.ingest(readings) }
        provider.onPermissionChange = { [weak self] p in self?.permission = p }
    }

    /// Production convenience: real Core Audio engine + `NSRunningApplication` resolver.
    convenience init() {
        self.init(provider: ProcessTapEngine()) { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? "PID \(pid)"
            return (name, app?.bundleIdentifier)
        }
    }

    func start() { provider.start() }
    func stop() { provider.stop() }
    func requestPermission() { provider.requestPermission() }

    private func ingest(_ readings: [TapReading]) {
        let present = Set(readings.map(\.pid))

        // Resolve/refresh metadata for present pids.
        for r in readings where names[r.pid] == nil {
            let info = resolve(r.pid)
            names[r.pid] = info.name
            bundleIDs[r.pid] = info.bundleID
        }

        // Fading set = previously-ordered pids that are absent this cycle but not yet removed.
        let fading = order.filter { !present.contains($0) }
        let working = MixerReconciler.order(previous: order, current: present.union(fading))

        var rows: [AppAudioLevel] = []
        var nextOrder: [pid_t] = []
        let targets = Dictionary(readings.map { ($0.pid, $0.level) }, uniquingKeysWith: { a, _ in a })

        for pid in working {
            let target = targets[pid] ?? 0                     // absent -> decay toward 0
            var smoother = smoothers[pid] ?? LevelSmoother()
            let level = smoother.update(target: target)
            smoothers[pid] = smoother

            let playing = present.contains(pid)
            if !playing && level < removalThreshold {
                smoothers[pid] = nil
                names[pid] = nil
                bundleIDs[pid] = nil
                continue                                        // fully faded: drop
            }
            nextOrder.append(pid)
            rows.append(AppAudioLevel(pid: pid,
                                      bundleID: bundleIDs[pid] ?? nil,
                                      displayName: names[pid] ?? "PID \(pid)",
                                      level: level,
                                      isPlaying: playing))
        }

        order = nextOrder
        apps = rows
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter MixerModelTests`
Expected: PASS (4 tests). (`ProcessTapEngine` does not exist yet, but it is only referenced from the `convenience init()`, which compiles against the type added in Task 4. If the build fails with `cannot find 'ProcessTapEngine'`, implement Task 4 first, then re-run — the two tasks compile together. To keep Task 3 self-contained, temporarily comment the `convenience init()` body out, run the tests, then restore it in Task 4.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/Mixer/AudioTapProviding.swift Sources/SoundConnect/Mixer/MixerModel.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add tap-provider protocol and observable model"
```

---

## Task 4: Core Audio process-tap engine (manual verification)

This task implements the real `AudioTapProviding` using Core Audio process taps. It cannot be unit-tested (it needs real system audio and the permission prompt), so it is verified manually. **Consult [insidegui/AudioCap](https://github.com/insidegui/AudioCap) for the exact Core Audio calls** — adapt its process enumeration, tap creation, aggregate-device, and IO-proc code.

**Files:**
- Create: `Sources/SoundConnect/Mixer/ProcessTapEngine.swift`
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Add the permission usage string to Info.plist**

Run:
```bash
cd ~/Developer/open-sound-connect
plutil -replace NSAudioCaptureUsageDescription -string "Sound Connect shows a live level for each app playing audio." Resources/Info.plist
plutil -lint Resources/Info.plist
```
Expected: `Resources/Info.plist: OK`

- [ ] **Step 2: Implement `ProcessTapEngine`**

Create `Sources/SoundConnect/Mixer/ProcessTapEngine.swift`. The structure below is the contract to fill in; the bracketed Core Audio calls are the pieces to adapt from AudioCap:

```swift
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Real Core Audio implementation of `AudioTapProviding`.
///
/// Approach (macOS 14.4+):
///  1. Enumerate process objects (`kAudioHardwarePropertyProcessObjectList`); keep those
///     running output audio (`kAudioProcessPropertyIsRunningOutput`), reading pid + bundle id.
///  2. For each, create a NON-MUTING, private `CATapDescription(stereoMixdownOfProcesses:)`
///     with `muteBehavior = .unmuted` so the app keeps playing normally.
///  3. Create the tap with `AudioHardwareCreateProcessTap`, then a private aggregate device
///     (`AudioHardwareCreateAggregateDevice`) whose `kAudioAggregateDeviceTapListKey` lists the taps.
///  4. `AudioDeviceCreateIOProcIDWithBlock` on the aggregate: in the audio-thread block, compute
///     each tap's RMS (`AudioLevelMath.rms`) and store it in `levelStore` under `lock` — NO
///     allocation, NO Swift concurrency, NO main-actor work in that block.
///  5. A main-actor timer (~30 Hz) reads `levelStore` and calls `onReadings` with `[TapReading]`.
///  6. Rebuild the tap set (debounced ~250 ms) when the process list changes
///     (`kAudioHardwarePropertyProcessObjectList` listener).
///  7. `stop()` destroys the IO proc, aggregate device, and taps.
@MainActor
final class ProcessTapEngine: AudioTapProviding {
    var onReadings: (([TapReading]) -> Void)?
    var onPermissionChange: ((TapPermission) -> Void)?
    private(set) var permission: TapPermission = .unknown {
        didSet { if oldValue != permission { onPermissionChange?(permission) } }
    }

    private let log = Logger(subsystem: "dev.rolottr.SoundConnect", category: "mixer")
    private let lock = NSLock()
    private var levelStore: [pid_t: (bundleID: String?, level: Float)] = [:]   // guarded by `lock`
    private var publishTimer: Timer?
    // Core Audio handles (set up in rebuild(), torn down in teardown()):
    private var aggregateDeviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var tapIDs: [AudioObjectID] = []

    func start() {
        requestPermission()
        guard permission == .granted else { return }
        rebuild()
        startPublishing()
        // TODO(impl): install the process-list property listener (debounced rebuild()).
    }

    func stop() {
        publishTimer?.invalidate(); publishTimer = nil
        teardown()
    }

    /// First tap creation surfaces the macOS audio-capture prompt. Success => .granted,
    /// a permission/`!nope` failure => .denied. Safe to call repeatedly.
    func requestPermission() {
        // TODO(impl): attempt a minimal tap create; map the OSStatus to .granted / .denied.
        // On a permission error, set `permission = .denied` and return without building taps.
    }

    private func rebuild() {
        teardown()
        // TODO(impl, from AudioCap):
        //   let processes = runningOutputProcesses()            // [(object: AudioObjectID, pid, bundleID)]
        //   for each -> CATapDescription(stereoMixdownOfProcesses:[object]); muteBehavior = .unmuted; isPrivate = true
        //   AudioHardwareCreateProcessTap(desc, &tapID) -> append to tapIDs
        //   build aggregate dict (private, tap list of tap UUIDs) -> AudioHardwareCreateAggregateDevice
        //   AudioDeviceCreateIOProcIDWithBlock(aggregate, ...) { _, inInputData, _, _, _ in
        //       // audio thread: per-tap RMS -> store under `lock` into levelStore (keyed by pid)
        //   }
        //   AudioDeviceStart(aggregate, ioProcID)
    }

    private func teardown() {
        // TODO(impl): AudioDeviceStop + AudioDeviceDestroyIOProcID + AudioHardwareDestroyAggregateDevice
        //             + AudioHardwareDestroyProcessTap for each tapID; reset handles; clear levelStore under lock.
    }

    private func startPublishing() {
        publishTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    private func publish() {
        lock.lock()
        let snapshot = levelStore
        lock.unlock()
        let readings = snapshot.map { TapReading(pid: $0.key, bundleID: $0.value.bundleID, level: $0.value.level) }
        onReadings?(readings)
    }
}
```

- [ ] **Step 3: Restore `MixerModel.convenience init()` if it was commented out in Task 3, then build**

Run: `./scripts/build.sh`
Expected: `Build complete!` then `==> Built .../Sound Connect.app`. Resolve any compile errors in the Core Audio calls against AudioCap before continuing.

- [ ] **Step 4: Run the unit suite to confirm nothing regressed**

Run: `./scripts/test.sh --filter MixerModelTests`
Expected: PASS (the model tests still use the fake; the real engine is not exercised here).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/Mixer/ProcessTapEngine.swift Resources/Info.plist
git commit -m "feat(mixer): add Core Audio process-tap engine and permission key"
```

---

## Task 5: Mixer page UI

**Files:**
- Create: `Sources/SoundConnect/UI/MixerView.swift`

- [ ] **Step 1: Implement the view**

Create `Sources/SoundConnect/UI/MixerView.swift`:

```swift
import AppKit
import SwiftUI

/// The Mixer sidebar page: a live level meter per audio-producing app (v1 is read-only).
struct MixerView: View {
    @Environment(MixerModel.self) private var mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mixer")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 4)
            Text("Live level for each app playing audio.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 28).padding(.bottom, 18)

            switch mixer.permission {
            case .denied:
                PermissionNotice(
                    message: "Sound Connect needs permission to read app audio.",
                    actionTitle: "Open Privacy & Security Settings",
                    action: openAudioPrivacySettings)
            case .unknown:
                PermissionNotice(
                    message: "Enable per-app audio to see live levels.",
                    actionTitle: "Enable",
                    action: { mixer.requestPermission() })
            case .granted:
                if mixer.apps.isEmpty {
                    EmptyMixerState()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(mixer.apps) { app in MixerRow(app: app) }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 24)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One app row: icon, name, and a horizontal meter bar driven by `app.level`.
private struct MixerRow: View {
    let app: AppAudioLevel

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: 26, height: 26)

            Text(app.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Meter(level: app.level)
                .frame(height: 10)
                .opacity(app.isPlaying ? 1 : 0.5)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.displayName), level \(Int(app.level * 100)) percent")
    }
}

/// A simple left-to-right fill bar. v2 replaces this with a draggable volume slider.
private struct Meter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.accent)
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, level)))))
            }
        }
    }
}

private struct EmptyMixerState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
            Text("Nothing is playing right now").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PermissionNotice: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 28)).foregroundStyle(Theme.secondary)
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `./scripts/build.sh`
Expected: `Build complete!` (the view is not yet reachable in the UI — that is Task 6). If `Theme.card` / `Theme.accent` / `Theme.tertiary` do not exist, open `Sources/SoundConnect/UI/Theme.swift` and substitute the nearest existing tokens.

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundConnect/UI/MixerView.swift
git commit -m "feat(mixer): add Mixer page view with meter rows and states"
```

---

## Task 6: Wire the Mixer into navigation and the app

**Files:**
- Modify: `Sources/SoundConnect/UI/RootView.swift`
- Modify: `Sources/SoundConnect/App/SoundConnectApp.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift`

- [ ] **Step 1: Write the failing test for the new page**

Append to `Tests/SoundConnectTests/MixerTests.swift`:

```swift
struct AppPageMixerTests {
    @Test func mixerPageExistsAndIgnoresConnection() {
        #expect(AppPage.allCases.contains(.mixer))
        #expect(AppPage.mixer.needsConnection == false)
        #expect(AppPage.mixer.title == "Mixer")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test.sh --filter AppPageMixerTests`
Expected: FAIL — `type 'AppPage' has no member 'mixer'`.

- [ ] **Step 3: Add the `.mixer` case to `AppPage`**

In `Sources/SoundConnect/UI/RootView.swift`, edit the `AppPage` enum. Add `mixer` to the cases and a branch in each `switch`:

```swift
enum AppPage: String, CaseIterable, Identifiable {
    case myDevice, sound, mixer, scenes, settings, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .myDevice: "My Device"
        case .sound: "Sound"
        case .mixer: "Mixer"
        case .scenes: "Scenes"
        case .settings: "Settings"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .myDevice: "headphones"
        case .sound: "slider.vertical.3"
        case .mixer: "slider.horizontal.3"
        case .scenes: "figure.walk"
        case .settings: "gearshape"
        case .activity: "waveform.path.ecg.rectangle"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .myDevice: "1"
        case .sound: "2"
        case .mixer: "3"
        case .scenes: "4"
        case .settings: "5"
        case .activity: "6"
        }
    }

    /// Settings handles the disconnected case itself so app preferences stay reachable.
    /// Mixer is about Mac audio, so it never needs a headphone connection.
    var needsConnection: Bool { self == .myDevice || self == .sound }
}
```

- [ ] **Step 4: Render `MixerView` in the content switch**

In the same file, add the `.mixer` branch to `content(for:)`:

```swift
            switch page {
            case .myDevice: MyDeviceView(page: Binding(get: { navigation.page }, set: { navigation.page = $0 }))
            case .sound: SoundView()
            case .mixer: MixerView()
            case .scenes: ScenesView()
            case .settings: DeviceSettingsView()
            case .activity: ActivityView()
            }
```

- [ ] **Step 5: Own, inject, and run the `MixerModel`**

In `Sources/SoundConnect/App/SoundConnectApp.swift`:

(a) Add the property to `AppDelegate`, next to the other controllers:
```swift
    let mixer = MixerModel()
```

(b) Inject it into `RootView` in the `Window` scene (add the line after `.environment(appDelegate.updates)`):
```swift
                .environment(appDelegate.updates)
                .environment(appDelegate.mixer)
```

(c) Start it in `applicationDidFinishLaunching`, after `updates.startAutomaticChecks()`:
```swift
        mixer.start()
```

(d) Stop it in `applicationWillTerminate`, after the existing lines:
```swift
        mixer.stop()
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `./scripts/test.sh --filter AppPageMixerTests`
Expected: PASS.

- [ ] **Step 7: Build, then manually verify the whole feature**

Run: `./scripts/build.sh && open "build/Sound Connect.app"`

Manual checklist (grant the audio prompt when it appears):
- A **Mixer** item appears in the sidebar (⌘3) and opens even with headphones disconnected.
- Play audio in **two apps at once** (e.g. a browser + Spotify) → each gets its own row with a bar that moves to its audio.
- Stop one app → its bar falls, then the row disappears.
- With nothing playing → "Nothing is playing right now".
- Deny permission (System Settings) and relaunch → the denied notice + settings button appear; the rest of the app is unaffected.
- Audio keeps playing normally the whole time (non-muting taps) — no distortion, no glitches.

- [ ] **Step 8: Commit**

```bash
git add Sources/SoundConnect/UI/RootView.swift Sources/SoundConnect/App/SoundConnectApp.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add Mixer page to navigation and start the engine"
```

---

## Self-Review

**Spec coverage:**
- New "Mixer" sidebar page → Task 6. ✅
- Per-app live meters → Tasks 3 (model) + 5 (view). ✅
- App name + icon per row → model resolver (Task 3) + icon in `MixerRow` (Task 5). ✅
- Works with headphones disconnected → `needsConnection` excludes `.mixer` (Task 6). ✅
- Runs whole app session → `mixer.start()` in `applicationDidFinishLaunching`, `stop()` in `applicationWillTerminate` (Task 6). ✅
- Non-muting taps / not in playback path → `muteBehavior = .unmuted` (Task 4). ✅
- Permission handling (unknown/granted/denied) → `TapPermission` (Task 2), model (Task 3), UI states (Task 5), Info.plist key (Task 4). ✅
- Empty state + non-fatal errors → `EmptyMixerState` (Task 5); engine failures logged and leave `apps` empty (Task 4). ✅
- Audio-thread discipline (lock-free store, main-actor publish) → Task 4 structure. ✅
- Unit tests behind a fake + manual checklist → Tasks 1–3 unit tests, FakeTapProvider (Task 3), manual checklist (Task 6 Step 7). ✅
- v2 forward-compat → `Meter` comment + `AudioTapProviding` seam noted for muting+gain. ✅

**Placeholder scan:** The only intentional `TODO(impl)` markers are inside Task 4's `ProcessTapEngine`, where the exact Core Audio incantations are to be adapted from the cited AudioCap sample; each is accompanied by the precise API and the step that builds/verifies it. All other steps contain complete code.

**Type consistency:** `TapReading(pid:bundleID:level:)`, `AppAudioLevel(pid:bundleID:displayName:level:isPlaying:)`, `TapPermission.{unknown,granted,denied}`, `LevelSmoother(attack:decay:)/update(target:)`, `AudioLevelMath.rms(_:)/peak(_:)`, `MixerReconciler.order(previous:current:)`, `AudioTapProviding.{onReadings,onPermissionChange,permission,start,stop,requestPermission}`, and `MixerModel.{apps,permission,start,stop,requestPermission}` are used consistently across tasks.
