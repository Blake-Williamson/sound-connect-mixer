# Mixer v2 — Phase 1: App Identification & Grouping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Mixer's per-process rows (showing `avconferenced` / `PID 24598`) with one row per real app — correct name and icon — by resolving each audio process to its owning app and grouping.

**Architecture:** A new `AppIdentityResolver` maps a pid to an `AppIdentity` (responsibility API → parent-process walk → self → known-daemon map → unknown), behind an `AppIdentityResolving` protocol. A pure `MixerGrouping` merges per-pid levels into one `MixerRow` per identity. `MixerModel` keeps its per-pid smoothing/fade, then groups; `MixerView` renders grouped rows with real icons. No volume/mixer yet — that's Phase 2.

**Tech Stack:** Swift 6 (language mode 5), SwiftUI + Observation (`@Observable`), AppKit (`NSRunningApplication`/`NSWorkspace`), Darwin (`sysctl`, `proc_name`, `dlsym`), swift-testing (`import Testing`, `@Test`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-10-27-mixer-volume-control-design.md` (this plan covers only the identification/grouping portions).

**Build:** `./scripts/build.sh` · **Test:** `./scripts/test.sh` (run a subset with `--filter NAME`).

**Branch:** `feature/mixer-volume` (already checked out).

---

## File Structure

**Create:**
- `Sources/SoundConnect/Mixer/AppIdentity.swift` — `AppIdentity` value type + `MixerRow` value type.
- `Sources/SoundConnect/Mixer/AppIdentityResolving.swift` — the resolver protocol.
- `Sources/SoundConnect/Mixer/MixerGrouping.swift` — pure grouping of per-pid entries into rows.
- `Sources/SoundConnect/Mixer/AppIdentityResolver.swift` — real pid→identity resolution.

**Modify:**
- `Sources/SoundConnect/Mixer/MixerModel.swift` — resolver now returns `AppIdentity`; group into `[MixerRow]`.
- `Sources/SoundConnect/Mixer/MixerTypes.swift` — remove the now-unused `AppAudioLevel`.
- `Sources/SoundConnect/UI/MixerView.swift` — render `[MixerRow]` with real app icons.
- `Tests/SoundConnectTests/MixerTests.swift` — update model tests to the grouped shape; add grouping + resolver tests.

---

## Task 1: Identity and row value types

**Files:**
- Create: `Sources/SoundConnect/Mixer/AppIdentity.swift`
- Create: `Sources/SoundConnect/Mixer/AppIdentityResolving.swift`

- [ ] **Step 1: Create the types**

Create `Sources/SoundConnect/Mixer/AppIdentity.swift`:

```swift
import Foundation

/// A resolved identity for an audio-producing process: the user-facing app it belongs to,
/// a shared system daemon, or an unknown process. Icon is derived in the view from `kind`.
struct AppIdentity: Equatable {
    enum Kind: Equatable {
        case app(bundleID: String)     // a real user-facing app
        case daemon(label: String)     // a shared system daemon (e.g. avconferenced -> "Video call")
        case unknown                    // could not be resolved
    }
    /// Stable grouping key: bundle id, "daemon:<name>", or "pid:<pid>".
    let key: String
    let displayName: String
    let kind: Kind
}

/// One grouped row in the Mixer: all processes of a single app merged together.
struct MixerRow: Identifiable, Equatable {
    let id: String          // == AppIdentity.key
    let displayName: String
    let kind: AppIdentity.Kind
    var level: Float        // 0...1, combined (max) across member processes
    var isPlaying: Bool     // true if any member is currently producing audio
    var pids: [pid_t]       // member processes (sorted)
}
```

Create `Sources/SoundConnect/Mixer/AppIdentityResolving.swift`:

```swift
import Foundation

/// Maps a process id to the app/daemon it belongs to. The real implementation is
/// `AppIdentityResolver`; tests inject a closure/fake.
protocol AppIdentityResolving {
    func identity(forPID pid: pid_t) -> AppIdentity
}
```

- [ ] **Step 2: Build to confirm the types compile**

Run: `./scripts/build.sh`
Expected: `Build complete!` then `Built .../Sound Connect.app`. (These types aren't used yet; this just confirms they compile.)

- [ ] **Step 3: Commit**

```bash
git add Sources/SoundConnect/Mixer/AppIdentity.swift Sources/SoundConnect/Mixer/AppIdentityResolving.swift
git commit -m "feat(mixer): add AppIdentity, MixerRow types and resolver protocol"
```

---

## Task 2: Pure row grouping

**Files:**
- Create: `Sources/SoundConnect/Mixer/MixerGrouping.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

Append to the END of `Tests/SoundConnectTests/MixerTests.swift`:

```swift
struct MixerGroupingTests {
    private func identity(_ key: String, _ name: String) -> AppIdentity {
        AppIdentity(key: key, displayName: name, kind: .app(bundleID: key))
    }

    @Test func mergesProcessesWithSameKeyTakingMaxLevel() {
        let entries = [
            MixerGrouping.Entry(pid: 30, level: 0.2, isPlaying: true, identity: identity("com.brave", "Brave")),
            MixerGrouping.Entry(pid: 10, level: 0.7, isPlaying: false, identity: identity("com.brave", "Brave")),
        ]
        let rows = MixerGrouping.rows(from: entries)
        #expect(rows.count == 1)
        #expect(rows[0].id == "com.brave")
        #expect(rows[0].displayName == "Brave")
        #expect(rows[0].level == 0.7)        // max of members
        #expect(rows[0].isPlaying)            // any member playing
        #expect(rows[0].pids == [10, 30])     // sorted
    }

    @Test func keepsDistinctAppsInFirstAppearanceOrder() {
        let entries = [
            MixerGrouping.Entry(pid: 1, level: 0.5, isPlaying: true, identity: identity("com.zoom", "Zoom")),
            MixerGrouping.Entry(pid: 2, level: 0.5, isPlaying: true, identity: identity("com.brave", "Brave")),
        ]
        let rows = MixerGrouping.rows(from: entries)
        #expect(rows.map(\.id) == ["com.zoom", "com.brave"])
    }

    @Test func emptyEntriesYieldNoRows() {
        #expect(MixerGrouping.rows(from: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter MixerGroupingTests`
Expected: FAIL — `cannot find 'MixerGrouping' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SoundConnect/Mixer/MixerGrouping.swift`:

```swift
import Foundation

/// Pure logic that merges per-process level entries into one `MixerRow` per app identity.
enum MixerGrouping {
    /// A single process's smoothed level plus its resolved identity.
    struct Entry: Equatable {
        let pid: pid_t
        let level: Float
        let isPlaying: Bool
        let identity: AppIdentity
    }

    /// Groups entries by `identity.key`. Combined level is the max across members; the row
    /// is playing if any member is; member pids are sorted. Rows keep first-appearance order.
    static func rows(from entries: [Entry]) -> [MixerRow] {
        var order: [String] = []
        var byKey: [String: MixerRow] = [:]
        for e in entries {
            let key = e.identity.key
            if var row = byKey[key] {
                row.level = max(row.level, e.level)
                row.isPlaying = row.isPlaying || e.isPlaying
                row.pids.append(e.pid)
                byKey[key] = row
            } else {
                order.append(key)
                byKey[key] = MixerRow(id: key,
                                      displayName: e.identity.displayName,
                                      kind: e.identity.kind,
                                      level: e.level,
                                      isPlaying: e.isPlaying,
                                      pids: [e.pid])
            }
        }
        return order.map { key in
            var row = byKey[key]!
            row.pids.sort()
            return row
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter MixerGroupingTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundConnect/Mixer/MixerGrouping.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add pure per-app row grouping"
```

---

## Task 3: Real app-identity resolver

The resolution pipeline is pure and testable by injecting its primitives; the default primitives call the real system APIs (verified on-device).

**Files:**
- Create: `Sources/SoundConnect/Mixer/AppIdentityResolver.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

Append to the END of `Tests/SoundConnectTests/MixerTests.swift`:

```swift
struct AppIdentityResolverTests {
    /// Builds a resolver whose primitives are driven by fixed test data.
    private func resolver(
        responsible: [pid_t: pid_t] = [:],
        parent: [pid_t: pid_t] = [:],
        apps: [pid_t: (String, String)] = [:],     // pid -> (bundleID, name)
        names: [pid_t: String] = [:],
        daemons: [String: String] = [:]
    ) -> AppIdentityResolver {
        AppIdentityResolver(
            responsiblePID: { responsible[$0] },
            parentPID: { parent[$0] },
            appForPID: { apps[$0].map { (bundleID: $0.0, name: $0.1) } },
            processName: { names[$0] },
            daemonLabels: daemons
        )
    }

    @Test func usesResponsibleProcessWhenItIsADifferentApp() {
        let r = resolver(responsible: [42: 7], apps: [7: ("com.brave.Browser", "Brave Browser")])
        let id = r.identity(forPID: 42)
        #expect(id.key == "com.brave.Browser")
        #expect(id.displayName == "Brave Browser")
        #expect(id.kind == .app(bundleID: "com.brave.Browser"))
    }

    @Test func fallsBackToParentWalkToFindOwningApp() {
        // 42 -> parent 20 (not an app) -> parent 9 (Spotify)
        let r = resolver(parent: [42: 20, 20: 9], apps: [9: ("com.spotify.client", "Spotify")])
        #expect(r.identity(forPID: 42).key == "com.spotify.client")
    }

    @Test func usesSelfWhenThePidIsItselfAnApp() {
        let r = resolver(apps: [5: ("com.apple.Music", "Music")])
        #expect(r.identity(forPID: 5).displayName == "Music")
    }

    @Test func mapsKnownDaemonToFriendlyLabel() {
        let r = resolver(names: [88: "avconferenced"], daemons: ["avconferenced": "Video call"])
        let id = r.identity(forPID: 88)
        #expect(id.key == "daemon:avconferenced")
        #expect(id.displayName == "Video call")
        #expect(id.kind == .daemon(label: "Video call"))
    }

    @Test func fallsBackToUnknownWithProcessNameThenPid() {
        #expect(resolver(names: [99: "weirdhelper"]).identity(forPID: 99) ==
                AppIdentity(key: "pid:99", displayName: "weirdhelper", kind: .unknown))
        #expect(resolver().identity(forPID: 77) ==
                AppIdentity(key: "pid:77", displayName: "PID 77", kind: .unknown))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter AppIdentityResolverTests`
Expected: FAIL — `cannot find 'AppIdentityResolver' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SoundConnect/Mixer/AppIdentityResolver.swift`:

```swift
import AppKit
import Darwin

/// Resolves a pid to the app/daemon it belongs to. The pipeline (first hit wins) is pure and
/// driven by injectable primitives; `AppIdentityResolver.live()` wires the real system calls.
struct AppIdentityResolver: AppIdentityResolving {
    /// Responsible process (how macOS attributes helpers/XPC to an owning app); nil if none/unavailable.
    var responsiblePID: (pid_t) -> pid_t?
    /// Direct parent pid, or nil.
    var parentPID: (pid_t) -> pid_t?
    /// (bundleID, localizedName) when the pid is a regular, user-facing app; nil otherwise.
    var appForPID: (pid_t) -> (bundleID: String, name: String)?
    /// Best-effort executable name for the pid.
    var processName: (pid_t) -> String?
    /// Known shared daemons mapped to friendly labels.
    var daemonLabels: [String: String]

    func identity(forPID pid: pid_t) -> AppIdentity {
        // 1. Responsible process, if it's a *different* regular app.
        if let rpid = responsiblePID(pid), rpid != pid, let app = appForPID(rpid) {
            return appIdentity(app)
        }
        // 2. Parent-process walk (bounded) to the first regular app.
        var current = pid
        for _ in 0..<8 {
            guard let ppid = parentPID(current), ppid > 1, ppid != current else { break }
            if let app = appForPID(ppid) { return appIdentity(app) }
            current = ppid
        }
        // 3. The pid itself is an app.
        if let app = appForPID(pid) { return appIdentity(app) }
        // 4. Known shared daemon.
        let name = processName(pid)
        if let name, let label = daemonLabels[name] {
            return AppIdentity(key: "daemon:\(name)", displayName: label, kind: .daemon(label: label))
        }
        // 5. Unknown.
        return AppIdentity(key: "pid:\(pid)", displayName: name ?? "PID \(pid)", kind: .unknown)
    }

    private func appIdentity(_ app: (bundleID: String, name: String)) -> AppIdentity {
        AppIdentity(key: app.bundleID, displayName: app.name, kind: .app(bundleID: app.bundleID))
    }

    /// Default friendly labels for shared system daemons that produce audio.
    static let defaultDaemonLabels: [String: String] = [
        "avconferenced": "Video call",
    ]

    /// Wires the real system primitives.
    @MainActor
    static func live() -> AppIdentityResolver {
        AppIdentityResolver(
            responsiblePID: { Self.realResponsiblePID($0) },
            parentPID: { Self.realParentPID($0) },
            appForPID: { Self.realAppForPID($0) },
            processName: { Self.realProcessName($0) },
            daemonLabels: Self.defaultDaemonLabels
        )
    }

    // MARK: Real primitives

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleSym: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static func realResponsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibleSym else { return nil }
        let rpid = fn(pid)
        return rpid > 0 ? rpid : nil
    }

    private static func realParentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    @MainActor
    private static func realAppForPID(_ pid: pid_t) -> (bundleID: String, name: String)? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier else { return nil }
        return (bundleID, app.localizedName ?? bundleID)
    }

    private static func realProcessName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)   // PROC_PIDPATHINFO_MAXSIZE is larger; name is short
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter AppIdentityResolverTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Build to confirm the real primitives compile**

Run: `./scripts/build.sh`
Expected: `Build complete!`. If `proc_name` is unresolved, add `import Darwin` is already present — it lives in libproc which `Darwin` re-exports; no extra import needed.

- [ ] **Step 6: Commit**

```bash
git add Sources/SoundConnect/Mixer/AppIdentityResolver.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): add app-identity resolver (responsibility, parent-walk, daemon map)"
```

---

## Task 4: Group the model and view by app identity

This swaps the per-pid rows for grouped `MixerRow`s end-to-end: model, view, wiring, and the model tests. `AppAudioLevel` is removed.

**Files:**
- Modify: `Sources/SoundConnect/Mixer/MixerModel.swift`
- Modify: `Sources/SoundConnect/Mixer/MixerTypes.swift`
- Modify: `Sources/SoundConnect/UI/MixerView.swift`
- Test: `Tests/SoundConnectTests/MixerTests.swift` (replace `MixerModelTests`)

- [ ] **Step 1: Replace the model-test body to the grouped shape**

In `Tests/SoundConnectTests/MixerTests.swift`, replace the ENTIRE existing `struct MixerModelTests { ... }` (the fake provider above it stays) with:

```swift
@MainActor
struct MixerModelTests {
    /// Resolver that maps each pid to its own single-app identity "App<pid>".
    private func model(_ fake: FakeTapProvider) -> MixerModel {
        MixerModel(provider: fake) { pid in
            AppIdentity(key: "app\(pid)", displayName: "App\(pid)", kind: .app(bundleID: "app\(pid)"))
        }
    }

    @Test func startForwardsToProvider() {
        let fake = FakeTapProvider()
        let m = model(fake)
        m.start()
        #expect(fake.started)
    }

    @Test func stopForwardsToProvider() {
        let fake = FakeTapProvider()
        let m = model(fake)
        m.start(); m.stop()
        #expect(!fake.started)
    }

    @Test func addsRowWithResolvedNameAndSmoothedLevel() {
        let fake = FakeTapProvider()
        let m = model(fake)
        fake.emit([TapReading(pid: 42, bundleID: nil, level: 1)])
        #expect(m.apps.count == 1)
        #expect(m.apps[0].id == "app42")
        #expect(m.apps[0].displayName == "App42")
        #expect(m.apps[0].pids == [42])
        #expect(m.apps[0].isPlaying)
        #expect(m.apps[0].level > 0 && m.apps[0].level < 1)
        let first = m.apps[0].level
        fake.emit([TapReading(pid: 42, bundleID: nil, level: 1)])
        #expect(m.apps[0].level > first)
    }

    @Test func mergesTwoProcessesOfSameAppIntoOneRow() {
        let fake = FakeTapProvider()
        // Both pids resolve to the same identity "shared".
        let m = MixerModel(provider: fake) { _ in
            AppIdentity(key: "shared", displayName: "Shared App", kind: .app(bundleID: "shared"))
        }
        fake.emit([TapReading(pid: 1, bundleID: nil, level: 1), TapReading(pid: 2, bundleID: nil, level: 1)])
        #expect(m.apps.count == 1)
        #expect(m.apps[0].id == "shared")
        #expect(m.apps[0].pids == [1, 2])
    }

    @Test func dropsRowAfterItFadesWhenAbsent() {
        let fake = FakeTapProvider()
        let m = model(fake)
        fake.emit([TapReading(pid: 7, bundleID: nil, level: 1)])
        #expect(m.apps.count == 1)
        for _ in 0..<200 { fake.emit([]) }
        #expect(m.apps.isEmpty)
    }

    @Test func rowIsMarkedNotPlayingWhileFading() {
        let fake = FakeTapProvider()
        let m = model(fake)
        fake.emit([TapReading(pid: 5, bundleID: nil, level: 1)])
        fake.emit([])
        #expect(m.apps.count == 1)
        #expect(!m.apps[0].isPlaying)
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
Expected: FAIL — the initializer closure now returns `AppIdentity`, and `m.apps[0].id`/`.pids` don't exist on the old `AppAudioLevel` model. Compile errors are the expected "failure" here.

- [ ] **Step 3: Refactor `MixerModel`**

Replace the entire contents of `Sources/SoundConnect/Mixer/MixerModel.swift` with:

```swift
import AppKit

/// Observable state for the Mixer page. Owns an `AudioTapProviding`, smooths per-process levels,
/// resolves each process to an app identity, and groups them into `[MixerRow]` (one per app).
/// Pure of Core Audio (behind the provider), so it is fully unit-testable with a fake provider.
@MainActor
@Observable
final class MixerModel {
    private(set) var apps: [MixerRow] = []
    private(set) var permission: TapPermission = .unknown

    private let provider: any AudioTapProviding
    /// pid -> resolved identity. Injected so tests avoid system calls.
    private let resolve: (pid_t) -> AppIdentity

    private var order: [pid_t] = []
    private var smoothers: [pid_t: LevelSmoother] = [:]
    private var identities: [pid_t: AppIdentity] = [:]

    /// Rows below this smoothed level and no longer producing audio are removed.
    private let removalThreshold: Float = 0.01

    init(provider: any AudioTapProviding, resolver: @escaping (pid_t) -> AppIdentity) {
        self.provider = provider
        self.resolve = resolver
        self.permission = provider.permission
        provider.onReadings = { [weak self] readings in self?.ingest(readings) }
        provider.onPermissionChange = { [weak self] p in self?.permission = p }
    }

    /// Production convenience: real Core Audio engine + real app-identity resolver.
    convenience init() {
        let resolver = AppIdentityResolver.live()
        self.init(provider: ProcessTapEngine()) { resolver.identity(forPID: $0) }
    }

    func start() { provider.start() }
    func stop() { provider.stop() }
    func requestPermission() { provider.requestPermission() }

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
        apps = MixerGrouping.rows(from: entries)
    }
}
```

- [ ] **Step 4: Remove the unused `AppAudioLevel`**

In `Sources/SoundConnect/Mixer/MixerTypes.swift`, delete the entire `AppAudioLevel` struct (lines beginning `struct AppAudioLevel: Identifiable, Equatable {` through its closing `}` and the doc comment above it). Keep `TapReading` and `TapPermission`.

- [ ] **Step 5: Update `MixerView` to render grouped rows with real icons**

Replace the `MixerRow` private view and its icon handling in `Sources/SoundConnect/UI/MixerView.swift`. Specifically, replace the existing `private struct MixerRow: View { ... }` with the renamed `AppRowView` below (the public value type is now `MixerRow`, so the view must be renamed to avoid a clash), and update the `ForEach` to use it.

Change the `ForEach` line in `MixerView.body` from:
```swift
                            ForEach(mixer.apps) { app in MixerRow(app: app) }
```
to:
```swift
                            ForEach(mixer.apps) { app in AppRowView(app: app) }
```

Replace the whole `private struct MixerRow: View { ... }` block with:
```swift
/// One grouped app row: icon, name, and a meter bar driven by `app.level`.
private struct AppRowView: View {
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

/// Resolves a row's icon from its identity kind: the real app icon for apps, an SF Symbol otherwise.
private struct AppIconView: View {
    let kind: AppIdentity.Kind
    let pids: [pid_t]

    var body: some View {
        if let image = appIcon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: symbolName).resizable().foregroundStyle(Theme.tertiary)
        }
    }

    private var appIcon: NSImage? {
        guard case let .app(bundleID) = kind else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        // Fallback: a running member process may expose the icon directly.
        return pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0)?.icon }.first
    }

    private var symbolName: String {
        switch kind {
        case .daemon: "waveform"
        case .unknown, .app: "app.dashed"
        }
    }
}
```

- [ ] **Step 6: Run the model tests, full suite, and build**

Run: `./scripts/test.sh --filter MixerModelTests`
Expected: PASS (7 tests).

Run: `./scripts/test.sh`
Expected: `Test run with N tests ... passed` — all suites green (AudioLevelMath, MixerReconciler, MixerGrouping, AppIdentityResolver, MixerModel, AppPageMixer, UpdateChecker, Playback). No reference to `AppAudioLevel` remains.

Run: `./scripts/build.sh`
Expected: `Built .../Sound Connect.app`.

- [ ] **Step 7: Manual on-device verification**

Run: `osascript -e 'quit app "Sound Connect"'; open "build/Sound Connect.app"`
Then open the Mixer page and confirm, with a few apps playing audio:
- Rows now show **real app names and icons** (e.g. Brave Browser, Spotify), not helper names or bare PIDs.
- A video/voice call shows as **"Video call"** instead of `avconferenced`.
- Multiple helper processes of one app collapse into a **single row**.
- Meters still move per app; stopping an app still fades and drops its row.

- [ ] **Step 8: Commit**

```bash
git add Sources/SoundConnect/Mixer/MixerModel.swift Sources/SoundConnect/Mixer/MixerTypes.swift Sources/SoundConnect/UI/MixerView.swift Tests/SoundConnectTests/MixerTests.swift
git commit -m "feat(mixer): group Mixer rows by resolved app identity with real icons"
```

---

## Self-Review

**Spec coverage (identification portions):**
- `AppIdentity` type with app/daemon/unknown → Task 1. ✅
- Resolution pipeline (responsibility → parent-walk → self → daemon map → unknown) → Task 3. ✅
- One row per app, merge helper processes, combined level = max → Tasks 2 & 4. ✅
- Real names + icons; `avconferenced` → "Video call" → Tasks 3 & 4. ✅
- Resolution once-per-pid, cached, off the audio thread → Task 4 (`identities` cache in `ingest`). ✅
- Testable behind a protocol with injected primitives → Tasks 1 & 3. ✅
- (Deferred to Phase 2, correctly absent here: volume faders, mixer engine, persistence, master toggle.)

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output.

**Type consistency:** `AppIdentity(key:displayName:kind:)`, `AppIdentity.Kind.{app(bundleID:),daemon(label:),unknown}`, `MixerRow(id:displayName:kind:level:isPlaying:pids:)`, `MixerGrouping.Entry(pid:level:isPlaying:identity:)`, `MixerGrouping.rows(from:)`, `AppIdentityResolving.identity(forPID:)`, `AppIdentityResolver(responsiblePID:parentPID:appForPID:processName:daemonLabels:)` and `.live()`, and `MixerModel(provider:resolver:)` with `resolver: (pid_t) -> AppIdentity` are used consistently across tasks. The SwiftUI row view is renamed `AppRowView` to avoid colliding with the `MixerRow` value type.
```
