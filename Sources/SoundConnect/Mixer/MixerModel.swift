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
        store.setVolume(v, forKey: id)   // no-op for ephemeral "pid:" keys; VolumeStore guards internally
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
                // Ephemeral (pid:) rows are session-only: drop their volume so the cache can't grow
                // unbounded. Stable app/daemon keys are kept so a returning app reuses its value.
                let key = identities[pid]?.key ?? "pid:\(pid)"
                if !VolumeStore.isStable(key) { volumes.removeValue(forKey: key) }
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
            rows[i].volume = volumes[key]!   // set just above; never nil here
        }
        // `apps` is replaced wholesale each cycle — any view binding must key off row.id, not index.
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
