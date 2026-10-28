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
