import Foundation

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

/// Engine mode / health, surfaced to the UI (a banner when bypassed).
enum MixerEngineStatus: Equatable {
    case metering                  // non-muting; not in the playback path
    case mixing                    // muting volume-mixer active
    case bypassed(reason: String)  // a failure or toggle-off restored normal audio
}
