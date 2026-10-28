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
