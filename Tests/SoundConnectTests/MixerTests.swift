import Testing
import Foundation
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

    @Test func rmsOfEmptyBufferIsZero() {
        #expect(AudioLevelMath.rms([]) == 0)
    }

    @Test func rmsFromSumSquaresCoreClampsAndGuards() {
        #expect(AudioLevelMath.rms(sumSquares: 0, count: 0) == 0)          // guard
        #expect(AudioLevelMath.rms(sumSquares: 4, count: 4) == 1)          // sqrt(1) = 1
        #expect(abs(AudioLevelMath.rms(sumSquares: 1, count: 4) - 0.5) < 0.0001)  // sqrt(0.25)
        #expect(AudioLevelMath.rms(sumSquares: 100, count: 1) == 1)        // clamp to 1
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
        let m = MixerModel(provider: fake) { _ in
            AppIdentity(key: "shared", displayName: "Shared App", kind: .app(bundleID: "shared"))
        }
        fake.emit([TapReading(pid: 1, bundleID: nil, level: 1), TapReading(pid: 2, bundleID: nil, level: 1)])
        #expect(m.apps.count == 1)
        #expect(m.apps[0].id == "shared")
        #expect(m.apps[0].pids == [1, 2])
    }

    @Test func rowStaysInPlaceWhenSecondProcessOfSameAppAppearsLater() {
        let fake = FakeTapProvider()
        // Two apps; "two" arrives first (row 0), "one" second (row 1). Then a second process
        // of "two" appears in a later cycle — its row must stay at position 0, not jump.
        let names: [pid_t: String] = [10: "two", 20: "one", 11: "two"]
        let m = MixerModel(provider: fake) { pid in
            let key = names[pid] ?? "x"
            return AppIdentity(key: key, displayName: key, kind: .app(bundleID: key))
        }
        fake.emit([TapReading(pid: 10, bundleID: nil, level: 1), TapReading(pid: 20, bundleID: nil, level: 1)])
        #expect(m.apps.map(\.id) == ["two", "one"])
        fake.emit([TapReading(pid: 10, bundleID: nil, level: 1),
                   TapReading(pid: 20, bundleID: nil, level: 1),
                   TapReading(pid: 11, bundleID: nil, level: 1)])
        #expect(m.apps.map(\.id) == ["two", "one"])   // order unchanged
        #expect(m.apps[0].pids == [10, 11])            // second process merged into the "two" row
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

@MainActor
struct AppPageMixerTests {
    @Test func mixerPageExistsAndIgnoresConnection() {
        #expect(AppPage.allCases.contains(.mixer))
        #expect(AppPage.mixer.needsConnection == false)
        #expect(AppPage.mixer.title == "Mixer")
    }
}

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

@MainActor
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
        #expect(m.apps[0].volume == 0.5)
        #expect(fake.lastGains[9] == 0.5)
        #expect(s.volume(forKey: "pid:9") == nil)
    }

    @Test func statusChangesPropagate() {
        let fake = FakeTapProvider(); let s = store()
        let m = model(fake, s)
        #expect(m.status == .metering)
        fake.emitStatus(.bypassed(reason: "test"))
        #expect(m.status == .bypassed(reason: "test"))
    }

    @Test func setVolumeOnAbsentRowIsSafe() {
        let fake = FakeTapProvider(); let s = store()
        let m = model(fake, s)
        fake.emit([TapReading(pid: 42, bundleID: nil, level: 1)])
        for _ in 0..<200 { fake.emit([]) }           // fade the row out
        #expect(m.apps.isEmpty)
        m.setVolume(0.2, forRow: "k42")              // row absent: must not crash
        #expect(m.apps.isEmpty)                      // still no row
        #expect(s.volume(forKey: "k42") == 0.2)      // stable value still persisted
    }
}
