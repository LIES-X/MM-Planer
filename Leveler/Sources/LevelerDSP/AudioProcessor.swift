import Foundation

/// Settings the UI hands to the audio thread.
public struct LevelerParameters: Equatable {
    /// Gain per EQ band in dB (−12 … +12), one value per `AudioProcessor.bandFrequencies`.
    public var bandGains: [Float]
    /// Whether the equalizer is applied.
    public var eqEnabled: Bool
    /// Whether the automatic volume leveling is active.
    public var levelerEnabled: Bool
    /// Leveling strength, 0 (off) … 1 (strong).
    public var strength: Float

    public init(
        bandGains: [Float] = Array(repeating: 0, count: AudioProcessor.bandFrequencies.count),
        eqEnabled: Bool = true,
        levelerEnabled: Bool = true,
        strength: Float = 0.7
    ) {
        self.bandGains = bandGains
        self.eqEnabled = eqEnabled
        self.levelerEnabled = levelerEnabled
        self.strength = strength
    }
}

/// Real-time stereo processor: 7-band EQ → loudness leveler → peak limiter.
///
/// EQ and leveler can be switched on and off independently; both fade in and
/// out over a few milliseconds so toggling never clicks. `process` runs on the
/// audio thread and never allocates or blocks. Parameter changes from the main
/// thread are handed over through a try-lock, so the audio thread simply keeps
/// the previous settings for one buffer if the UI is writing at that moment.
public final class AudioProcessor {
    public static let bandFrequencies: [Float] = [60, 150, 400, 1_000, 2_500, 6_000, 14_000]
    public static let bandQ: Float = 1.0
    public static let maxBandGainDb: Float = 12

    /// Loudness the leveler steers towards (short-term RMS, dBFS).
    public static let targetLevelDb: Float = -20
    /// Below this level the signal counts as silence and is never boosted.
    public static let gateDb: Float = -50
    /// Maximum boost / cut of the leveler at full strength.
    public static let maxBoostDb: Float = 12
    public static let maxCutDb: Float = 30
    /// Output peak ceiling of the limiter (−2 dBFS).
    public static let ceiling: Float = 0.794

    public static let maxFrames = 16_384

    private let bandCount = AudioProcessor.bandFrequencies.count

    // Shared between threads (guarded by `lock`).
    private let lock = NSLock()
    private let pendingCoeffs: UnsafeMutablePointer<Float>
    private var pendingEQ = true
    private var pendingLeveler = true
    private var pendingStrength: Float = 0.7
    private var pendingDirty = false

    // Owned by the audio thread.
    private let coeffs: UnsafeMutablePointer<Float>       // 5 per band: b0 b1 b2 a1 a2
    private let filterState: UnsafeMutablePointer<Float>  // 4 per band: zL1 zL2 zR1 zR2
    private var eqEnabled = true
    private var levelerEnabled = true
    private var strength: Float = 0.7
    private var eqMix: Float = 1          // 0 = dry, 1 = equalized; smoothed
    private var envelope: Float = 0
    private var gainDb: Float = 0
    private var limiterGain: Float = 1

    private var detectorAttack: Float = 0
    private var detectorRelease: Float = 0
    private var gainAttack: Float = 0
    private var gainRelease: Float = 0
    private var gainBypass: Float = 0
    private var eqMixCoef: Float = 0
    private var limiterRelease: Float = 0

    // Written by the audio thread, read by the UI (plain floats; a stale value is harmless).
    private let meters: UnsafeMutablePointer<Float>

    public private(set) var sampleRate: Float = 48_000
    private var parameters = LevelerParameters()

    public init() {
        coeffs = .allocate(capacity: bandCount * 5)
        pendingCoeffs = .allocate(capacity: bandCount * 5)
        filterState = .allocate(capacity: bandCount * 4)
        meters = .allocate(capacity: 2)
        meters.initialize(repeating: 0, count: 2)
        prepare(sampleRate: 48_000)
    }

    deinit {
        coeffs.deallocate()
        pendingCoeffs.deallocate()
        filterState.deallocate()
        meters.deallocate()
    }

    /// RMS level of the most recent input buffer (linear, 0 … 1).
    public var inputLevel: Float { meters[0] }
    /// RMS level of the most recent output buffer (linear, 0 … 1).
    public var outputLevel: Float { meters[1] }
    /// Current leveler gain in dB (for display / tests).
    public var currentGainDb: Float { gainDb }

    /// Resets all state for a new sample rate. Call only while audio is stopped.
    public func prepare(sampleRate: Float) {
        self.sampleRate = max(8_000, sampleRate)
        func coef(_ seconds: Float) -> Float { 1 - expf(-1 / (seconds * self.sampleRate)) }
        detectorAttack = coef(0.005)
        detectorRelease = coef(0.300)
        gainAttack = coef(0.015)
        gainRelease = coef(2.5)
        gainBypass = coef(0.080)
        eqMixCoef = coef(0.020)
        limiterRelease = coef(0.120)

        filterState.initialize(repeating: 0, count: bandCount * 4)
        envelope = 0
        gainDb = 0
        limiterGain = 1
        meters[0] = 0
        meters[1] = 0

        lock.lock()
        Self.computeCoefficients(parameters.bandGains, sampleRate: self.sampleRate, into: pendingCoeffs)
        coeffs.update(from: pendingCoeffs, count: bandCount * 5)
        eqEnabled = parameters.eqEnabled
        levelerEnabled = parameters.levelerEnabled
        strength = parameters.strength
        eqMix = eqEnabled ? 1 : 0
        pendingEQ = parameters.eqEnabled
        pendingLeveler = parameters.levelerEnabled
        pendingStrength = parameters.strength
        pendingDirty = false
        lock.unlock()
    }

    /// Hands new settings to the audio thread. Call from the main thread.
    public func update(_ newParameters: LevelerParameters) {
        var p = newParameters
        if p.bandGains.count != bandCount {
            p.bandGains = Array(p.bandGains.prefix(bandCount))
                + Array(repeating: 0, count: max(0, bandCount - p.bandGains.count))
        }
        p.bandGains = p.bandGains.map { min(max($0, -Self.maxBandGainDb), Self.maxBandGainDb) }
        p.strength = min(max(p.strength, 0), 1)
        parameters = p

        lock.lock()
        Self.computeCoefficients(p.bandGains, sampleRate: sampleRate, into: pendingCoeffs)
        pendingEQ = p.eqEnabled
        pendingLeveler = p.levelerEnabled
        pendingStrength = p.strength
        pendingDirty = true
        lock.unlock()
    }

    /// Processes one stereo buffer in place. Real-time safe.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if lock.try() {
            if pendingDirty {
                coeffs.update(from: pendingCoeffs, count: bandCount * 5)
                eqEnabled = pendingEQ
                levelerEnabled = pendingLeveler
                strength = pendingStrength
                pendingDirty = false
            }
            lock.unlock()
        }
        guard frames > 0 else { return }

        let bands = bandCount
        let target = Self.targetLevelDb
        let gate = Self.gateDb
        let maxBoost = Self.maxBoostDb * strength
        let maxCut = Self.maxCutDb * strength
        let ceiling = Self.ceiling
        let eqTarget: Float = eqEnabled ? 1 : 0
        let limiterActive = eqEnabled || levelerEnabled
        let antiDenormal: Float = 1e-20

        var inSum: Float = 0
        var outSum: Float = 0

        for i in 0..<frames {
            let dryL = left[i] + antiDenormal
            let dryR = right[i] + antiDenormal
            inSum += dryL * dryL + dryR * dryR

            // 1) Equalizer: peaking biquads, transposed direct form II. The filters
            //    always run so switching the EQ back on is seamless; the result is
            //    cross-faded with the dry signal.
            var l = dryL
            var r = dryR
            for b in 0..<bands {
                let c = coeffs + b * 5
                let s = filterState + b * 4
                let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
                let yl = b0 * l + s[0]
                s[0] = b1 * l - a1 * yl + s[1]
                s[1] = b2 * l - a2 * yl
                l = yl
                let yr = b0 * r + s[2]
                s[2] = b1 * r - a1 * yr + s[3]
                s[3] = b2 * r - a2 * yr
                r = yr
            }
            eqMix += eqMixCoef * (eqTarget - eqMix)
            l = dryL + eqMix * (l - dryL)
            r = dryR + eqMix * (r - dryR)

            // 2) Leveler: fast-rising / slow-falling RMS detector drives a smoothed gain.
            //    The detector always runs so re-enabling reacts immediately.
            let ms = 0.5 * (l * l + r * r)
            envelope += (ms > envelope ? detectorAttack : detectorRelease) * (ms - envelope)
            if levelerEnabled {
                let levelDb = 10 * log10f(envelope + 1e-12)
                let targetGain: Float
                if levelDb > gate {
                    let desired = (target - levelDb) * strength
                    targetGain = min(max(desired, -maxCut), maxBoost)
                } else {
                    targetGain = gainDb // silence: hold, never pump up noise
                }
                gainDb += (targetGain < gainDb ? gainAttack : gainRelease) * (targetGain - gainDb)
            } else {
                gainDb += gainBypass * (0 - gainDb)
            }
            let g = powf(10, gainDb * 0.05)
            l *= g
            r *= g

            // 3) Limiter: instant attack, smooth release, hard ceiling. Off when
            //    neither EQ nor leveler is active so the signal passes untouched.
            let peak = max(abs(l), abs(r))
            let needed: Float = (limiterActive && peak > ceiling) ? ceiling / peak : 1
            if needed < limiterGain {
                limiterGain = needed
            } else {
                limiterGain += limiterRelease * (1 - limiterGain)
                if limiterGain > needed { limiterGain = needed }
            }
            l *= limiterGain
            r *= limiterGain

            left[i] = l
            right[i] = r
            outSum += l * l + r * r
        }

        let n = Float(frames * 2)
        meters[0] = sqrtf(inSum / n)
        meters[1] = sqrtf(outSum / n)
    }

    // MARK: - Filter design

    /// RBJ cookbook peaking filter, normalized (a0 = 1).
    static func peaking(frequency: Float, q: Float, gainDb: Float, sampleRate: Float) -> (Float, Float, Float, Float, Float) {
        if abs(gainDb) < 0.01 { return (1, 0, 0, 0, 0) }
        let f = min(frequency, 0.45 * sampleRate)
        let a = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * f / sampleRate
        let alpha = sinf(w0) / (2 * q)
        let cosw = cosf(w0)
        let a0 = 1 + alpha / a
        return (
            (1 + alpha * a) / a0,
            (-2 * cosw) / a0,
            (1 - alpha * a) / a0,
            (-2 * cosw) / a0,
            (1 - alpha / a) / a0
        )
    }

    private static func computeCoefficients(_ gains: [Float], sampleRate: Float, into out: UnsafeMutablePointer<Float>) {
        for (b, f) in bandFrequencies.enumerated() {
            let g = b < gains.count ? gains[b] : 0
            let c = peaking(frequency: f, q: bandQ, gainDb: g, sampleRate: sampleRate)
            out[b * 5 + 0] = c.0
            out[b * 5 + 1] = c.1
            out[b * 5 + 2] = c.2
            out[b * 5 + 3] = c.3
            out[b * 5 + 4] = c.4
        }
    }
}
