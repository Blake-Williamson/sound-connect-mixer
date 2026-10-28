import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Thread-safe store the audio IO blocks write into and the main-actor publish timer reads.
/// Kept separate from `ProcessTapEngine` (which is `@MainActor`) so the non-isolated audio
/// callbacks never touch main-actor state.
private final class LevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [pid_t: (bundleID: String?, level: Float)] = [:]

    func set(_ pid: pid_t, bundleID: String?, level: Float) {
        lock.lock(); values[pid] = (bundleID, level); lock.unlock()
    }
    func snapshot() -> [pid_t: (bundleID: String?, level: Float)] {
        lock.lock(); defer { lock.unlock() }; return values
    }
    func clear() { lock.lock(); values.removeAll(); lock.unlock() }
}

/// Lock-free per-tap gains + levels for the mixing render callback. Aligned 32-bit `Float`
/// loads/stores are atomic on Apple platforms, so the real-time audio thread reads gains and
/// writes levels through these fixed arrays with NO lock and NO allocation — the requirement for
/// glitch-free audio. Allocated per mixer build; freed on teardown.
private final class MixState: @unchecked Sendable {
    let pids: [pid_t]
    let count: Int
    let gainPtr: UnsafeMutablePointer<Float>
    let levelPtr: UnsafeMutablePointer<Float>
    private let indexByPID: [pid_t: Int]

    init(pids: [pid_t]) {
        self.pids = pids
        self.count = max(pids.count, 1)
        gainPtr = .allocate(capacity: count); gainPtr.initialize(repeating: 1, count: count)
        levelPtr = .allocate(capacity: count); levelPtr.initialize(repeating: 0, count: count)
        var idx: [pid_t: Int] = [:]
        for (i, p) in pids.enumerated() { idx[p] = i }
        indexByPID = idx
    }
    deinit { gainPtr.deallocate(); levelPtr.deallocate() }

    /// Main thread: write new gains (per-element aligned Float store, atomic — no lock needed).
    func applyGains(_ g: [pid_t: Float]) {
        for (pid, value) in g { if let i = indexByPID[pid] { gainPtr[i] = value } }
    }
    /// Main thread: read the latest per-app levels.
    func levelSnapshot() -> [pid_t: Float] {
        var out: [pid_t: Float] = [:]
        for (i, p) in pids.enumerated() { out[p] = levelPtr[i] }
        return out
    }
}

/// One live tap: its tap object, the private aggregate device wrapping it, and the IO proc.
private struct TapHandle {
    var pid: pid_t
    var tapID: AudioObjectID
    var aggregateID: AudioDeviceID
    var ioProcID: AudioDeviceIOProcID?
}

/// Real Core Audio implementation of `AudioTapProviding` (macOS 14.4+).
///
/// For each app currently producing output audio it creates a NON-MUTING process tap wrapped in
/// a private aggregate device, and an IO block that computes that app's RMS level. A main-actor
/// timer publishes the latest levels ~30×/sec. Non-muting means the app keeps playing normally —
/// this engine only ever *reads* levels; it is never in the playback path.
///
/// Reference: Apple's process-tap sample `insidegui/AudioCap`.
@MainActor
final class ProcessTapEngine: AudioTapProviding {
    var onReadings: (([TapReading]) -> Void)?
    var onPermissionChange: ((TapPermission) -> Void)?
    var onStatusChange: ((MixerEngineStatus) -> Void)?
    private(set) var permission: TapPermission = .unknown {
        didSet { if oldValue != permission { onPermissionChange?(permission) } }
    }
    private(set) var status: MixerEngineStatus = .metering {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }
    private var volumeControlEnabled = false
    private var currentGains: [pid_t: Float] = [:]
    private var mixState: MixState?
    private var mixerAggregateID: AudioDeviceID = 0
    private var mixerIOProcID: AudioDeviceIOProcID?

    private let log = Logger(subsystem: "dev.rolottr.SoundConnect", category: "mixer")
    private let store = LevelStore()
    private let ioQueue = DispatchQueue(label: "dev.rolottr.SoundConnect.mixer.io")
    private var handles: [TapHandle] = []
    private var publishTimer: Timer?
    private var scanTimer: Timer?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var rebuildScheduled = false

    func start() {
        guard publishTimer == nil else { return }   // already running
        requestPermission()
        guard permission == .granted else { return }
        rebuild()
        installProcessListListener()
        startPublishing()
        startScanning()
    }

    func stop() {
        publishTimer?.invalidate(); publishTimer = nil
        scanTimer?.invalidate(); scanTimer = nil
        removeProcessListListener()
        teardown()
        store.clear()
        onReadings?([])
    }

    /// Attempts a minimal global tap to surface / detect the macOS audio-capture TCC prompt.
    /// Success => `.granted` (the probe tap is destroyed immediately); a failure => `.denied`.
    func requestPermission() {
        let probe = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        probe.isPrivate = true
        probe.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(probe, &tapID)
        if status == noErr {
            AudioHardwareDestroyProcessTap(tapID)
            permission = .granted
        } else {
            log.error("Tap permission probe failed: \(status)")
            permission = .denied
        }
    }

    // MARK: Tap lifecycle

    private func rebuild() {
        teardown()
        if volumeControlEnabled {
            if buildMixer() { status = .mixing } else { bypass("Could not start the volume mixer") }
        } else {
            for process in runningOutputProcesses() {
                if let handle = makeTap(for: process) { handles.append(handle) }
            }
            status = .metering
        }
    }

    /// Tear the mixer down and fall back to metering so audio is never left muted.
    private func bypass(_ reason: String) {
        teardown()
        for process in runningOutputProcesses() {
            if let handle = makeTap(for: process) { handles.append(handle) }
        }
        volumeControlEnabled = false
        status = .bypassed(reason: reason)
    }

    /// Returns true if the muting mixer started. On any failure returns false (caller bypasses).
    private func buildMixer() -> Bool {
        let processes = runningOutputProcesses()
        guard !processes.isEmpty else { return true }   // nothing to mix yet; becomes active on next rebuild

        var subTapUIDs: [String] = []
        for process in processes {
            let desc = CATapDescription(stereoMixdownOfProcesses: [process.object])
            desc.isPrivate = true
            desc.muteBehavior = .mutedWhenTapped
            desc.name = "SoundConnectMix-\(process.pid)"
            var tapID = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != kAudioObjectUnknown else {
                log.error("mixer: tap failed for pid \(process.pid)"); return false
            }
            handles.append(TapHandle(pid: process.pid, tapID: tapID, aggregateID: 0, ioProcID: nil))
            subTapUIDs.append(desc.uuid.uuidString)
        }

        guard let outputUID = defaultOutputDeviceUID() else { return false }

        let aggUID = UUID().uuidString
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SoundConnectMixer",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outputUID]],
            kAudioAggregateDeviceTapListKey as String: subTapUIDs.map {
                [kAudioSubTapUIDKey as String: $0, kAudioSubTapDriftCompensationKey as String: true]
            },
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]
        var aggID = AudioDeviceID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID) == noErr,
              aggID != kAudioObjectUnknown else {
            log.error("mixer: aggregate create failed"); return false
        }
        mixerAggregateID = aggID

        let pids = processes.map(\.pid)
        let state = MixState(pids: pids)
        state.applyGains(currentGains)
        mixState = state
        // The block strongly captures `state`, keeping its buffers alive, and reads gains / writes
        // levels through its pointers per callback — no lock, no allocation (real-time safe).
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            Self.renderMix(input: inInputData, output: outOutputData,
                           gains: state.gainPtr, levels: state.levelPtr, count: state.count)
        }
        var ioProcID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, ioQueue, ioBlock) == noErr, let ioProcID else {
            log.error("mixer: io proc failed"); return false
        }
        mixerIOProcID = ioProcID
        guard AudioDeviceStart(aggID, ioProcID) == noErr else { log.error("mixer: start failed"); return false }
        return true
    }

    private func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?; var usz = UInt32(MemoryLayout<CFString?>.size)
        guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &usz, $0) }) == noErr,
              let s = uid?.takeRetainedValue() as String? else { return nil }
        return s
    }

    /// Audio thread (real-time): mix each tap's input into the output scaled by its gain, and store
    /// pre-gain RMS. Reads `gains[i]` / writes `levels[i]` as plain aligned Float — NO lock, NO
    /// allocation, NO Swift collection mutation, so the render deadline is never missed.
    private static func renderMix(input: UnsafePointer<AudioBufferList>,
                                  output: UnsafeMutablePointer<AudioBufferList>,
                                  gains: UnsafeMutablePointer<Float>,
                                  levels: UnsafeMutablePointer<Float>,
                                  count: Int) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)
        for ob in outBuffers { if let d = ob.mData { memset(d, 0, Int(ob.mDataByteSize)) } }
        guard let outBuf = outBuffers.first, let outData = outBuf.mData else { return }
        let outSamples = outData.assumingMemoryBound(to: Float.self)
        let outCap = Int(outBuf.mDataByteSize) / MemoryLayout<Float>.size
        for (i, ib) in inBuffers.enumerated() {
            guard i < count, let inData = ib.mData else { continue }
            let frames = Int(ib.mDataByteSize) / MemoryLayout<Float>.size
            let inSamples = inData.assumingMemoryBound(to: Float.self)
            let g = gains[i]
            let n = min(frames, outCap)
            var sum: Float = 0
            for f in 0..<n { let s = inSamples[f]; sum += s * s; outSamples[f] += s * g }
            if frames > n { for f in n..<frames { let s = inSamples[f]; sum += s * s } }
            levels[i] = frames > 0 ? min(1, (sum / Float(frames)).squareRoot()) : 0
        }
    }

    private func teardown() {
        if let ioProcID = mixerIOProcID, mixerAggregateID != 0 {
            AudioDeviceStop(mixerAggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(mixerAggregateID, ioProcID)
        }
        if mixerAggregateID != 0 { AudioHardwareDestroyAggregateDevice(mixerAggregateID) }
        mixerAggregateID = 0; mixerIOProcID = nil
        mixState = nil   // IO proc is stopped+destroyed above, so no callback can still read its buffers
        for handle in handles {
            if let ioProcID = handle.ioProcID, handle.aggregateID != 0 {
                AudioDeviceStop(handle.aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(handle.aggregateID, ioProcID)
            }
            if handle.aggregateID != 0 { AudioHardwareDestroyAggregateDevice(handle.aggregateID) }
            AudioHardwareDestroyProcessTap(handle.tapID)
        }
        handles.removeAll()
    }

    private func makeTap(for process: (object: AudioObjectID, pid: pid_t, bundleID: String?)) -> TapHandle? {
        let description = CATapDescription(stereoMixdownOfProcesses: [process.object])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "SoundConnect-\(process.pid)"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else {
            log.error("Failed to create tap for pid \(process.pid)")
            return nil
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SoundConnectMixer-\(process.pid)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var aggregateID = AudioDeviceID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID) == noErr,
              aggregateID != kAudioObjectUnknown else {
            log.error("Failed to create aggregate device for pid \(process.pid)")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let store = self.store
        let pid = process.pid
        let bundleID = process.bundleID
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            let level = Self.rmsLevel(of: inInputData)
            store.set(pid, bundleID: bundleID, level: level)
        }

        var ioProcID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, ioBlock) == noErr,
              let ioProcID else {
            log.error("Failed to create IO proc for pid \(process.pid)")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        if AudioDeviceStart(aggregateID, ioProcID) != noErr {
            log.error("Failed to start aggregate device for pid \(process.pid)")
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        return TapHandle(pid: pid, tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
    }

    /// RMS across every float sample in every buffer of the tap's input. Runs on the audio thread:
    /// math only, no allocation of Swift collections, no locks beyond the store's.
    private static func rmsLevel(of bufferList: UnsafePointer<AudioBufferList>) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var sumSquares: Float = 0
        var count: Int = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                let s = samples[i]
                sumSquares += s * s
            }
            count += frames
        }
        return AudioLevelMath.rms(sumSquares: sumSquares, count: count)
    }

    // MARK: Process discovery

    private func runningOutputProcesses() -> [(object: AudioObjectID, pid: pid_t, bundleID: String?)] {
        var result: [(AudioObjectID, pid_t, String?)] = []
        for object in processObjectList() where isRunningOutput(object) {
            let pid = processPID(object)
            guard pid > 0 else { continue }
            result.append((object, pid, processBundleID(object)))
        }
        return result
    }

    private func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func processPID(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }

    private func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var cfString: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfString) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value = cfString?.takeRetainedValue() else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    // MARK: Process-list listener (debounced rebuild when apps start/stop playing)

    private func installProcessListListener() {
        guard listenerBlock == nil else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            listenerBlock = block
        }
    }

    private func removeProcessListListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        listenerBlock = nil
    }

    private func scheduleRebuild() {
        // While mixing, a full teardown+recreate of the aggregate device causes an audible dropout.
        // Muting taps can also make the "producing output" set flicker, which would otherwise trigger
        // a rebuild every scan. So suppress automatic rebuilds while mixing — the mix stays stable for
        // the apps that were playing when volume control was turned on. (Metering still rescans live.)
        // Trade-off: an app that starts after you enable volume control isn't mixed until you toggle
        // volume control off and on again.
        guard !volumeControlEnabled else { return }
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.permission == .granted else { return }
            self.rebuild()
        }
    }

    // MARK: Publishing

    private func startPublishing() {
        publishTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    /// The process-list listener only fires when audio process *objects* are added/removed. A
    /// long-lived app (e.g. Spotify) that merely *starts* producing output doesn't change that
    /// list, so poll the running-output set ~1Hz and rebuild when it changes.
    private func startScanning() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanForChanges() }
        }
    }

    private func rescanForChanges() {
        guard permission == .granted else { return }
        let current = Set(runningOutputProcesses().map(\.pid))
        let have = Set(handles.map(\.pid))
        if current != have { scheduleRebuild() }
    }

    private func publish() {
        if let mixState {   // mixing: levels come from the lock-free render buffers
            onReadings?(mixState.levelSnapshot().map { TapReading(pid: $0.key, bundleID: nil, level: $0.value) })
        } else {            // metering: levels come from the per-process IO blocks
            let snapshot = store.snapshot()
            onReadings?(snapshot.map { TapReading(pid: $0.key, bundleID: $0.value.bundleID, level: $0.value.level) })
        }
    }

    func setVolumeControlEnabled(_ enabled: Bool) {
        guard enabled != volumeControlEnabled else { return }
        volumeControlEnabled = enabled
        guard publishTimer != nil, permission == .granted else { return }  // not running yet
        rebuild()   // rebuild in the new mode
    }

    func setGains(_ gains: [pid_t: Float]) {
        currentGains = gains
        mixState?.applyGains(gains)   // lock-free: aligned Float stores the audio thread reads directly
    }
}
