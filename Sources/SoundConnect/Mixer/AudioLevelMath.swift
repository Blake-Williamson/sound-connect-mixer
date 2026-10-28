/// Pure helpers for turning a buffer of float audio samples into a 0...1 level.
enum AudioLevelMath {
    /// RMS from a precomputed sum-of-squares and sample count, clamped to 0...1. `count` 0 is 0.
    /// Shared by the array helper below and the real-time audio engine (`ProcessTapEngine`), so
    /// both the tested and production paths use the same clamp/guard math.
    static func rms(sumSquares: Float, count: Int) -> Float {
        guard count > 0 else { return 0 }
        return min(1, (sumSquares / Float(count)).squareRoot())
    }

    /// Root-mean-square of the samples, clamped to 0...1. Empty buffer is 0.
    static func rms(_ samples: [Float]) -> Float {
        rms(sumSquares: samples.reduce(Float(0)) { $0 + $1 * $1 }, count: samples.count)
    }

    /// Largest absolute sample value, clamped to 0...1. Empty buffer is 0.
    static func peak(_ samples: [Float]) -> Float {
        min(1, samples.reduce(Float(0)) { max($0, abs($1)) })
    }
}

/// Smooths a 0...1 level so meters look natural: quick to rise, gentle to fall.
struct LevelSmoother {
    private(set) var value: Float = 0
    var attack: Float
    var decay: Float

    init(attack: Float = 0.5, decay: Float = 0.12) {
        self.attack = attack
        self.decay = decay
    }

    /// Moves `value` a fraction of the way toward `target` and returns it.
    @discardableResult
    mutating func update(target: Float) -> Float {
        let coeff = target > value ? attack : decay
        value += (target - value) * coeff
        return value
    }
}
