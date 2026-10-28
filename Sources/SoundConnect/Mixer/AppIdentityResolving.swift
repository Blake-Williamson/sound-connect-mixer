import Foundation

/// Maps a process id to the app/daemon it belongs to. The real implementation is
/// `AppIdentityResolver`; tests inject a closure/fake.
///
/// `@MainActor`: the live implementation reads `NSRunningApplication` (main-actor isolated),
/// and the only caller (`MixerModel`) is already on the main actor. Gating the entry point here
/// makes that an enforced constraint rather than a latent assumption.
@MainActor
protocol AppIdentityResolving {
    func identity(forPID pid: pid_t) -> AppIdentity
}
