import SwiftUI

/// Pure mapping between a single unified slider position and the headphone's noise state.
/// Position 0 = Noise Canceling (max isolation); positions 1…(1+span) = Ambient level lo…hi.
/// Sony's noise canceling is on/off, so the continuous axis is the ambient (transparency) level.
enum AmbientSliderMapping {
    /// Slider positions for an ambient range: 0 for NC, then one per ambient level.
    static func positionRange(for range: ClosedRange<Int>) -> ClosedRange<Int> {
        0...(1 + (range.upperBound - range.lowerBound))
    }

    /// The slider position that represents a given noise state. Non-NC/ambient modes (e.g. Off)
    /// rest at 0 — their active state is shown by the separate Off button, not the slider.
    static func position(for noise: NoiseControl, range: ClosedRange<Int>) -> Int {
        switch noise.mode {
        case .ambient:
            let clamped = min(range.upperBound, max(range.lowerBound, noise.ambientLevel))
            return 1 + (clamped - range.lowerBound)
        default:
            return 0
        }
    }

    /// The mode + ambient level for a slider position. A nil `ambientLevel` means "leave it" (NC).
    static func change(forPosition pos: Int, range: ClosedRange<Int>) -> (mode: NoiseMode, ambientLevel: Int?) {
        guard pos > 0 else { return (.noiseCancelling, nil) }
        let level = min(range.upperBound, range.lowerBound + (pos - 1))
        return (.ambient, level)
    }
}

/// One continuous control spanning Noise Canceling → Ambient levels. Reuses `LevelSlider`'s
/// drag/commit throttling and the controller's verified `requestNoise` write path.
struct AmbientSlider: View {
    @Environment(HeadphoneController.self) private var controller
    let cap: NoiseControlCapability
    /// The state to display (current, or the pending intent for responsiveness).
    let shown: NoiseControl
    @Binding var rememberedLevel: Int

    var body: some View {
        let range = cap.ambientRange
        VStack(alignment: .leading, spacing: 10) {
            Text(stateLabel(shown))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            LevelSlider(value: AmbientSliderMapping.position(for: shown, range: range),
                        range: AmbientSliderMapping.positionRange(for: range),
                        enabled: controller.canWrite,
                        accessibilityName: "Noise canceling and ambient level",
                        onDrag: { pos in
                            if let level = AmbientSliderMapping.change(forPosition: pos, range: range).ambientLevel {
                                controller.dragAmbientLevel(level)
                            }
                        },
                        onCommit: { pos in commit(pos, range) })
            HStack {
                Text("Noise Canceling").font(.caption11).foregroundStyle(Theme.tertiary)
                Spacer()
                Text("Ambient").font(.caption11).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func stateLabel(_ n: NoiseControl) -> String {
        switch n.mode {
        case .noiseCancelling: "Noise Canceling"
        case .ambient: "Ambient · \(n.ambientLevel)"
        case .off: "Off"
        default: n.mode.title
        }
    }

    private func commit(_ pos: Int, _ range: ClosedRange<Int>) {
        let change = AmbientSliderMapping.change(forPosition: pos, range: range)
        if let level = change.ambientLevel, !controller.isReplay { rememberedLevel = level }
        controller.requestNoise { value in
            value.mode = change.mode
            if let level = change.ambientLevel { value.ambientLevel = level }
        }
    }
}
