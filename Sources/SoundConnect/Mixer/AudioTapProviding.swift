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

    /// Current engine status.
    var status: MixerEngineStatus { get }
    /// Called when the engine status changes.
    var onStatusChange: ((MixerEngineStatus) -> Void)? { get set }

    /// Enable/disable the muting volume-mixer. Off = metering only (never in the playback path).
    func setVolumeControlEnabled(_ enabled: Bool)
    /// Per-process output gains (0...1). Applied while mixing; retained for when mixing starts.
    func setGains(_ gains: [pid_t: Float])

    func start()
    func stop()
    /// Triggers the macOS permission prompt if it has not been shown yet.
    func requestPermission()
}
