import AppKit
import SwiftUI

/// The Mixer sidebar page: a live level meter per audio-producing app (v1 is read-only).
struct MixerView: View {
    @Environment(MixerModel.self) private var mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mixer")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline) {
                Text(mixer.volumeControlEnabled ? "Drag to set how much of each app you hear." : "Live level for each app playing audio.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                Spacer()
                Toggle("Volume control", isOn: Binding(
                    get: { mixer.volumeControlEnabled },
                    set: { mixer.setVolumeControlEnabled($0) }))
                    .toggleStyle(.switch).tint(Theme.accent)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 28).padding(.bottom, 18)

            if case let .bypassed(reason) = mixer.status {
                Text("Volume control paused — audio restored to normal. (\(reason))")
                    .font(.caption).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 28).padding(.bottom, 10)
            }

            switch mixer.permission {
            case .denied:
                PermissionNotice(
                    message: "Sound Connect needs permission to read app audio.",
                    actionTitle: "Open Privacy & Security Settings",
                    action: openAudioPrivacySettings)
            case .unknown:
                PermissionNotice(
                    message: "Enable per-app audio to see live levels.",
                    actionTitle: "Enable",
                    action: { mixer.requestPermission() })
            case .granted:
                if mixer.apps.isEmpty {
                    EmptyMixerState()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(mixer.apps) { app in AppRowView(app: app) }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 24)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AppRowView: View {
    @Environment(MixerModel.self) private var mixer
    let app: MixerRow

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(kind: app.kind, pids: app.pids)
                .frame(width: 26, height: 26)

            Text(app.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            if mixer.volumeControlEnabled {
                Slider(value: Binding(
                    get: { Double(app.volume) },
                    set: { mixer.setVolume(Float($0), forRow: app.id) }),
                    in: 0...1)
                    .controlSize(.small).tint(Theme.accent)
                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary).frame(width: 40, alignment: .trailing)
                Meter(level: app.level).frame(width: 60, height: 6).opacity(app.isPlaying ? 1 : 0.4)
            } else {
                Meter(level: app.level).frame(height: 10).opacity(app.isPlaying ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.displayName)\(mixer.volumeControlEnabled ? ", volume \(Int(app.volume * 100)) percent" : ", level \(Int(app.level * 100)) percent")")
    }
}

/// Resolves a row's icon from its identity kind: the real app icon for apps, an SF Symbol otherwise.
private struct AppIconView: View {
    let kind: AppIdentity.Kind
    let pids: [pid_t]

    var body: some View {
        if let image = appIcon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: symbolName).resizable().foregroundStyle(Theme.tertiary)
        }
    }

    private var appIcon: NSImage? {
        // Called from `body` (~30Hz). NSWorkspace caches urlForApplication + icon(forFile:)
        // internally, so this is a cheap lookup, not per-frame disk I/O.
        guard case let .app(bundleID) = kind else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0)?.icon }.first
    }

    private var symbolName: String {
        switch kind {
        case .daemon: "waveform"
        case .unknown, .app: "app.dashed"
        }
    }
}

/// A simple left-to-right fill bar. v2 replaces this with a draggable volume slider.
private struct Meter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.accent)
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, level)))))
            }
        }
    }
}

private struct EmptyMixerState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
            Text("Nothing is playing right now").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PermissionNotice: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 28)).foregroundStyle(Theme.secondary)
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
