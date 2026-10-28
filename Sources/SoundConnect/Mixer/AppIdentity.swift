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
    var volume: Float = 1.0 // 0...1 user-set output level (100% = normal)
}
