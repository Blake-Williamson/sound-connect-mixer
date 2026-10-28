import Testing
@testable import SoundConnect

struct AmbientSliderMappingTests {
    private let range = 0...20

    @Test func positionRangeSpansNCPlusAmbient() {
        #expect(AmbientSliderMapping.positionRange(for: 0...20) == 0...21)
        #expect(AmbientSliderMapping.positionRange(for: 0...10) == 0...11)
    }

    @Test func noiseCancelingIsPositionZero() {
        let n = NoiseControl(mode: .noiseCancelling, ambientLevel: 5, focusOnVoice: false)
        #expect(AmbientSliderMapping.position(for: n, range: range) == 0)
    }

    @Test func ambientLevelMapsToOnePlusLevel() {
        #expect(AmbientSliderMapping.position(for: NoiseControl(mode: .ambient, ambientLevel: 0, focusOnVoice: false), range: range) == 1)
        #expect(AmbientSliderMapping.position(for: NoiseControl(mode: .ambient, ambientLevel: 8, focusOnVoice: false), range: range) == 9)
        #expect(AmbientSliderMapping.position(for: NoiseControl(mode: .ambient, ambientLevel: 20, focusOnVoice: false), range: range) == 21)
    }

    @Test func offRestsAtPositionZero() {
        #expect(AmbientSliderMapping.position(for: NoiseControl(mode: .off, ambientLevel: 5, focusOnVoice: false), range: range) == 0)
    }

    @Test func changeZeroIsNoiseCanceling() {
        let c = AmbientSliderMapping.change(forPosition: 0, range: range)
        #expect(c.mode == .noiseCancelling)
        #expect(c.ambientLevel == nil)
    }

    @Test func changePositiveIsAmbientLevel() {
        let c1 = AmbientSliderMapping.change(forPosition: 1, range: range)
        #expect(c1.mode == .ambient && c1.ambientLevel == 0)
        #expect(AmbientSliderMapping.change(forPosition: 9, range: range).ambientLevel == 8)
        #expect(AmbientSliderMapping.change(forPosition: 21, range: range).ambientLevel == 20)
    }

    @Test func changeClampsAboveRange() {
        let c = AmbientSliderMapping.change(forPosition: 100, range: range)
        #expect(c.mode == .ambient && c.ambientLevel == 20)
    }

    @Test func roundTripsAcrossAmbientRange() {
        for level in range {
            let pos = AmbientSliderMapping.position(for: NoiseControl(mode: .ambient, ambientLevel: level, focusOnVoice: false), range: range)
            let back = AmbientSliderMapping.change(forPosition: pos, range: range)
            #expect(back.mode == .ambient && back.ambientLevel == level)
        }
    }
}
