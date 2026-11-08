import XCTest
@testable import LevelerDSP

final class AudioProcessorTests: XCTestCase {
    private let sampleRate: Float = 48_000
    private let block = 512

    /// Runs a sine through the processor and returns (input RMS, output RMS, output peak)
    /// measured over the last `measureSeconds`.
    private func run(
        _ processor: AudioProcessor,
        amplitude: Float,
        frequency: Float = 1_000,
        seconds: Float,
        measureSeconds: Float = 0.5
    ) -> (inRMS: Float, outRMS: Float, outPeak: Float) {
        let total = Int(seconds * sampleRate)
        let measureFrom = total - Int(measureSeconds * sampleRate)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { l.deallocate(); r.deallocate() }

        var inSum: Float = 0, outSum: Float = 0, peak: Float = 0, count = 0
        var n = 0
        while n < total {
            let frames = min(block, total - n)
            for i in 0..<frames {
                let v = amplitude * sinf(2 * .pi * frequency * Float(n + i) / sampleRate)
                l[i] = v
                r[i] = v
            }
            var inputs = [Float](repeating: 0, count: frames)
            for i in 0..<frames { inputs[i] = l[i] }
            processor.process(left: l, right: r, frames: frames)
            for i in 0..<frames where n + i >= measureFrom {
                inSum += inputs[i] * inputs[i]
                outSum += l[i] * l[i]
                peak = max(peak, abs(l[i]), abs(r[i]))
                count += 1
            }
            n += frames
        }
        return (sqrtf(inSum / Float(count)), sqrtf(outSum / Float(count)), peak)
    }

    private func makeProcessor(_ params: LevelerParameters) -> AudioProcessor {
        let p = AudioProcessor()
        p.update(params)
        p.prepare(sampleRate: sampleRate)
        return p
    }

    func testNeutralSettingsPassAudioThrough() {
        let p = makeProcessor(LevelerParameters(levelerEnabled: false, strength: 0.7))
        let m = run(p, amplitude: 0.25, seconds: 1)
        XCTAssertEqual(m.outRMS, m.inRMS, accuracy: m.inRMS * 0.01)
    }

    func testLoudSceneGetsQuieter() {
        let p = makeProcessor(LevelerParameters(levelerEnabled: true, strength: 1))
        let m = run(p, amplitude: 0.7, seconds: 2)
        let reductionDb = 20 * log10f(m.outRMS / m.inRMS)
        XCTAssertLessThan(reductionDb, -10, "loud signal should be turned down clearly, got \(reductionDb) dB")
    }

    func testQuietDialogueGetsLouder() {
        let p = makeProcessor(LevelerParameters(levelerEnabled: true, strength: 1))
        let m = run(p, amplitude: 0.02, seconds: 10)
        let boostDb = 20 * log10f(m.outRMS / m.inRMS)
        XCTAssertGreaterThan(boostDb, 8, "quiet signal should be turned up, got \(boostDb) dB")
        XCTAssertLessThanOrEqual(boostDb, AudioProcessor.maxBoostDb + 0.5)
    }

    func testSilenceIsNotBoosted() {
        let p = makeProcessor(LevelerParameters(levelerEnabled: true, strength: 1))
        let m = run(p, amplitude: 0.0005, seconds: 4)
        XCTAssertEqual(m.outRMS, m.inRMS, accuracy: m.inRMS * 0.05)
    }

    func testSuddenExplosionIsCaughtQuickly() {
        let p = makeProcessor(LevelerParameters(levelerEnabled: true, strength: 1))
        _ = run(p, amplitude: 0.02, seconds: 8)          // quiet dialogue, gain goes up
        let m = run(p, amplitude: 0.9, seconds: 0.3, measureSeconds: 0.2)
        XCTAssertLessThanOrEqual(m.outPeak, AudioProcessor.ceiling + 1e-4)
        XCTAssertLessThan(m.outRMS, 0.2, "a sudden loud passage must not stay loud")
    }

    func testEqualizerBoostsItsBand() {
        var gains = [Float](repeating: 0, count: AudioProcessor.bandFrequencies.count)
        gains[3] = 6 // 1 kHz
        let p = makeProcessor(LevelerParameters(bandGains: gains, levelerEnabled: false))
        let m = run(p, amplitude: 0.1, frequency: 1_000, seconds: 1)
        let gainDb = 20 * log10f(m.outRMS / m.inRMS)
        XCTAssertEqual(gainDb, 6, accuracy: 0.3)
    }

    func testEqualizerLeavesDistantBandsAlone() {
        var gains = [Float](repeating: 0, count: AudioProcessor.bandFrequencies.count)
        gains[0] = 8 // 60 Hz
        let p = makeProcessor(LevelerParameters(bandGains: gains, levelerEnabled: false))
        let m = run(p, amplitude: 0.1, frequency: 6_000, seconds: 1)
        let gainDb = 20 * log10f(m.outRMS / m.inRMS)
        XCTAssertEqual(gainDb, 0, accuracy: 0.3)
    }

    func testLimiterKeepsPeaksBelowCeiling() {
        var gains = [Float](repeating: 0, count: AudioProcessor.bandFrequencies.count)
        gains[3] = 12
        let p = makeProcessor(LevelerParameters(bandGains: gains, levelerEnabled: false))
        let m = run(p, amplitude: 0.9, seconds: 1)
        XCTAssertLessThanOrEqual(m.outPeak, AudioProcessor.ceiling + 1e-4)
    }

    func testEqualizerCanBeSwitchedOffOnItsOwn() {
        var gains = [Float](repeating: 0, count: AudioProcessor.bandFrequencies.count)
        gains[3] = 6
        let p = makeProcessor(LevelerParameters(bandGains: gains, eqEnabled: false, levelerEnabled: false))
        let off = run(p, amplitude: 0.1, seconds: 1)
        XCTAssertEqual(20 * log10f(off.outRMS / off.inRMS), 0, accuracy: 0.1, "EQ off must pass audio through unchanged")

        p.update(LevelerParameters(bandGains: gains, eqEnabled: true, levelerEnabled: false))
        let on = run(p, amplitude: 0.1, seconds: 0.5, measureSeconds: 0.3)
        XCTAssertEqual(20 * log10f(on.outRMS / on.inRMS), 6, accuracy: 0.3, "EQ on must apply the band gain")
    }

    func testLevelerWorksWithEqualizerOff() {
        let p = makeProcessor(LevelerParameters(eqEnabled: false, levelerEnabled: true, strength: 1))
        let m = run(p, amplitude: 0.7, seconds: 2)
        XCTAssertLessThan(20 * log10f(m.outRMS / m.inRMS), -10)
    }

    func testEverythingOffIsBitTransparent() {
        let p = makeProcessor(LevelerParameters(eqEnabled: false, levelerEnabled: false))
        let m = run(p, amplitude: 0.95, seconds: 1)
        XCTAssertEqual(m.outRMS, m.inRMS, accuracy: 1e-4)
        XCTAssertGreaterThan(m.outPeak, AudioProcessor.ceiling, "limiter must not touch audio when nothing is active")
    }

    func testSwitchingLevelerOffReleasesGainQuickly() {
        let p = makeProcessor(LevelerParameters(levelerEnabled: true, strength: 1))
        _ = run(p, amplitude: 0.7, seconds: 2)
        XCTAssertLessThan(p.currentGainDb, -10)
        p.update(LevelerParameters(levelerEnabled: false, strength: 1))
        _ = run(p, amplitude: 0.7, seconds: 0.5, measureSeconds: 0.1)
        XCTAssertEqual(p.currentGainDb, 0, accuracy: 0.1)
    }

    func testParameterUpdateWhileRunning() {
        let p = makeProcessor(LevelerParameters(levelerEnabled: false))
        _ = run(p, amplitude: 0.1, seconds: 0.2)
        var gains = [Float](repeating: 0, count: AudioProcessor.bandFrequencies.count)
        gains[3] = -6
        p.update(LevelerParameters(bandGains: gains, eqEnabled: true, levelerEnabled: false))
        let m = run(p, amplitude: 0.1, seconds: 0.5, measureSeconds: 0.3)
        XCTAssertEqual(20 * log10f(m.outRMS / m.inRMS), -6, accuracy: 0.3)
    }
}
