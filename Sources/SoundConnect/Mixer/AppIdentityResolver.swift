@preconcurrency import AppKit
import Darwin

/// Resolves a pid to the app/daemon it belongs to. The pipeline (first hit wins) is pure and
/// driven by injectable primitives; `AppIdentityResolver.live()` wires the real system calls.
struct AppIdentityResolver: AppIdentityResolving {
    /// Responsible process (how macOS attributes helpers/XPC to an owning app); nil if none/unavailable.
    var responsiblePID: (pid_t) -> pid_t?
    /// Direct parent pid, or nil.
    var parentPID: (pid_t) -> pid_t?
    /// (bundleID, localizedName) when the pid is a regular, user-facing app; nil otherwise.
    /// `@MainActor` because the live implementation reads `NSRunningApplication`.
    var appForPID: @MainActor (pid_t) -> (bundleID: String, name: String)?
    /// Best-effort executable name for the pid.
    var processName: (pid_t) -> String?
    /// Known shared daemons mapped to friendly labels.
    var daemonLabels: [String: String]

    @MainActor
    func identity(forPID pid: pid_t) -> AppIdentity {
        if let rpid = responsiblePID(pid), rpid != pid, let app = appForPID(rpid) {
            return appIdentity(app)
        }
        var current = pid
        for _ in 0..<8 {
            guard let ppid = parentPID(current), ppid > 1, ppid != current else { break }
            if let app = appForPID(ppid) { return appIdentity(app) }
            current = ppid
        }
        if let app = appForPID(pid) { return appIdentity(app) }
        let name = processName(pid)
        if let name, let label = daemonLabels[name] {
            return AppIdentity(key: "daemon:\(name)", displayName: label, kind: .daemon(label: label))
        }
        return AppIdentity(key: "pid:\(pid)", displayName: name ?? "PID \(pid)", kind: .unknown)
    }

    private func appIdentity(_ app: (bundleID: String, name: String)) -> AppIdentity {
        AppIdentity(key: app.bundleID, displayName: app.name, kind: .app(bundleID: app.bundleID))
    }

    /// Default friendly labels for shared system daemons that produce audio.
    static let defaultDaemonLabels: [String: String] = [
        "avconferenced": "Video call",       // Zoom / FaceTime / Teams call audio
        "systemsoundserverd": "System sounds", // macOS UI sounds, alerts, Siri, etc.
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

    // MARK: - Real primitives

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
        var buffer = [CChar](repeating: 0, count: 256)   // proc_name returns a short name (kernel p_name, <=MAXCOMLEN); 256 is ample
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
