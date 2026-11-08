import Foundation
import LevelerDSP
import ServiceManagement
import SwiftUI

struct EQPreset: Identifiable {
    let name: String
    let gains: [Double]
    var id: String { name }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    static let presets: [EQPreset] = [
        EQPreset(name: "Film", gains: [2, 1, -1, 1, 3, 2, 0]),
        EQPreset(name: "Musik", gains: [4, 2, 0, -1, 1, 2, 3]),
        EQPreset(name: "Sprache", gains: [-3, -2, 0, 2, 4, 3, 0]),
        EQPreset(name: "Nacht", gains: [-5, -3, 0, 1, 2, 1, -2]),
    ]
    static let bandLabels = ["60", "150", "400", "1k", "2.5k", "6k", "14k"]
    static let flat = [Double](repeating: 0, count: 7)

    @Published var levelerOn: Bool { didSet { changed() } }
    /// 0 … 100
    @Published var strength: Double { didSet { changed() } }
    /// dB per band, −12 … +12
    @Published var bands: [Double] { didSet { changed() } }
    @Published var preset: String? { didSet { defaults.set(preset, forKey: Keys.preset) } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Leveler: Autostart konnte nicht geändert werden: \(error)")
            }
        }
    }

    let engine = SystemAudioEngine()
    let history = LevelHistory()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let levelerOn = "levelerOn"
        static let strength = "strength"
        static let bands = "bands"
        static let preset = "preset"
    }

    private init() {
        let d = UserDefaults.standard
        levelerOn = d.object(forKey: Keys.levelerOn) as? Bool ?? true
        strength = d.object(forKey: Keys.strength) as? Double ?? 70
        let storedBands = d.array(forKey: Keys.bands) as? [Double]
        bands = (storedBands?.count == 7 ? storedBands : nil) ?? AppState.presets[0].gains
        preset = storedBands == nil ? AppState.presets[0].name : d.string(forKey: Keys.preset)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        pushToEngine()
    }

    var strengthLabel: String {
        strength < 35 ? "Sanft" : (strength < 75 ? "Ausgewogen" : "Stark")
    }

    func apply(_ preset: EQPreset) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            bands = preset.gains
            self.preset = preset.name
        }
    }

    func resetEQ() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            bands = AppState.flat
            preset = nil
        }
    }

    func setBand(_ index: Int, to value: Double) {
        let v = min(max(value.rounded(), -12), 12)
        guard bands.indices.contains(index), bands[index] != v else { return }
        bands[index] = v
        if preset != nil { preset = nil }
    }

    private func changed() {
        defaults.set(levelerOn, forKey: Keys.levelerOn)
        defaults.set(strength, forKey: Keys.strength)
        defaults.set(bands, forKey: Keys.bands)
        pushToEngine()
    }

    private func pushToEngine() {
        engine.processor.update(LevelerParameters(
            bandGains: bands.map { Float($0) },
            levelerEnabled: levelerOn,
            strength: Float(strength / 100)
        ))
    }
}

/// Rolling input/output loudness used by the wave and spectrum animations.
final class LevelHistory {
    static let length = 120
    private(set) var input = [Float](repeating: 0, count: LevelHistory.length)
    private(set) var output = [Float](repeating: 0, count: LevelHistory.length)
    private(set) var latestOutput: Float = 0
    private var lastSample = Date.distantPast
    private var smoothIn: Float = 0
    private var smoothOut: Float = 0

    /// Samples the processor meters at most 30× per second. Main thread.
    func tick(now: Date, processor: AudioProcessor) {
        guard now.timeIntervalSince(lastSample) >= 1.0 / 30 else { return }
        lastSample = now
        smoothIn += (Self.normalize(processor.inputLevel) - smoothIn) * 0.45
        smoothOut += (Self.normalize(processor.outputLevel) - smoothOut) * 0.45
        input.removeFirst()
        input.append(smoothIn)
        output.removeFirst()
        output.append(smoothOut)
        latestOutput = smoothOut
    }

    /// Linear RMS → 0 … 1 (−60 dBFS … −6 dBFS).
    private static func normalize(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10f(rms)
        return min(max((db + 60) / 54, 0), 1)
    }
}
