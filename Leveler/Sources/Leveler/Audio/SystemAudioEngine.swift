import CoreAudio
import Foundation
import LevelerDSP

/// Captures all system audio with a Core Audio process tap (original muted),
/// runs it through `AudioProcessor` and plays the result on the current
/// output device via a private aggregate device.
final class SystemAudioEngine: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case needsPermission
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var outputDeviceName: String = "Ausgabegerät"

    let processor = AudioProcessor()

    private let render = RenderContext()
    private let ioQueue = DispatchQueue(label: "de.leveler.audio-io", qos: .userInteractive)

    private var tapID = CoreAudioHelpers.unknown
    private var aggregateID = CoreAudioHelpers.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    private var listenersInstalled = false
    private var restartWork: DispatchWorkItem?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerDevice = CoreAudioHelpers.unknown

    deinit { stop() }

    // MARK: - Public

    /// Starts (or restarts) processing. Main thread.
    func start() {
        installSystemListeners()
        switch AudioCapturePermission.status {
        case .granted:
            startNow()
        case .unknown:
            requestPermissionAndStart()
        case .denied:
            stop()
            status = .needsPermission
        }
    }

    /// Asks for the system-audio permission, then starts.
    func requestPermissionAndStart() {
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            if granted { self.startNow() } else { self.status = .needsPermission }
        }
    }

    /// Stops processing and gives the system its original audio back. Main thread.
    func stop() {
        restartWork?.cancel()
        restartWork = nil
        removeSampleRateListener()
        if aggregateID != CoreAudioHelpers.unknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = CoreAudioHelpers.unknown

        if tapID != CoreAudioHelpers.unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = CoreAudioHelpers.unknown
        tapDescription = nil
        if status == .running || status == .starting { status = .stopped }
    }

    // MARK: - Setup

    private func startNow() {
        stop()
        status = .starting
        do {
            try startTap()
            status = .running
        } catch {
            stop()
            status = .failed(error.localizedDescription)
        }
    }

    private func startTap() throws {
        let outputDevice = try CoreAudioHelpers.defaultOutputDevice()
        let outputUID = try CoreAudioHelpers.deviceUID(outputDevice)
        outputDeviceName = CoreAudioHelpers.deviceName(outputDevice) ?? "Ausgabegerät"

        // Tap everything except our own output (otherwise we would hear ourselves in a loop,
        // and "muted when tapped" would silence our own playback).
        var ownProcess = CoreAudioHelpers.processObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.processList(ownProcess))
        description.uuid = UUID()
        description.name = "Leveler"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        tapDescription = description

        var tap = CoreAudioHelpers.unknown
        try check(AudioHardwareCreateProcessTap(description, &tap), "Systemton-Tap konnte nicht erstellt werden")
        tapID = tap
        let tapFormat = try CoreAudioHelpers.tapFormat(tap)

        let subDevice: [String: Any] = [kAudioSubDeviceUIDKey: outputUID]
        let subTap: [String: Any] = [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: description.uuid.uuidString,
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Leveler",
            kAudioAggregateDeviceUIDKey: "de.leveler.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [subDevice],
            kAudioAggregateDeviceTapListKey: [subTap],
        ]
        var aggregate = CoreAudioHelpers.unknown
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                  "Audiogerät konnte nicht erstellt werden")
        aggregateID = aggregate

        let sampleRate = (try? CoreAudioHelpers.nominalSampleRate(aggregate)) ?? tapFormat.mSampleRate
        processor.prepare(sampleRate: Float(sampleRate > 0 ? sampleRate : 48_000))
        render.processor = processor
        render.tapChannels = max(1, Int(tapFormat.mChannelsPerFrame))

        let context = render
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) { _, input, _, output, _ in
            context.render(input: input, output: output)
        }, "Audioverarbeitung konnte nicht gestartet werden")
        ioProcID = procID

        try check(AudioDeviceStart(aggregate, procID), "Audiogerät konnte nicht gestartet werden")

        // If our process object did not exist yet (it appears once we are an audio
        // client), exclude it now so we never tap our own output.
        if ownProcess == CoreAudioHelpers.unknown {
            ownProcess = CoreAudioHelpers.processObject(for: getpid())
            if ownProcess != CoreAudioHelpers.unknown {
                description.processes = Self.processList(ownProcess)
                CoreAudioHelpers.setTapDescription(description, on: tap)
            }
        }

        installSampleRateListener(on: aggregate)
    }

    private static func processList(_ process: AudioObjectID) -> [AudioObjectID] {
        process == CoreAudioHelpers.unknown ? [] : [process]
    }

    // MARK: - Listeners

    private func installSystemListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        var addr = CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CoreAudioHelpers.systemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.scheduleRestart()
        }
    }

    private func installSampleRateListener(on device: AudioObjectID) {
        var addr = CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart()
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, block) == noErr {
            sampleRateListener = block
            sampleRateListenerDevice = device
        }
    }

    private func removeSampleRateListener() {
        guard let block = sampleRateListener else { return }
        var addr = CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(sampleRateListenerDevice, &addr, DispatchQueue.main, block)
        sampleRateListener = nil
        sampleRateListenerDevice = CoreAudioHelpers.unknown
    }

    /// Device switches (headphones, AirPods, HDMI…) fire several notifications – restart once.
    private func scheduleRestart() {
        guard status == .running || status == .starting || isFailed else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// Everything the audio thread touches. Allocated once, never resized.
private final class RenderContext {
    var processor: AudioProcessor?
    var tapChannels = 2
    let capacity = AudioProcessor.maxFrames
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>

    init() {
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)
        let sampleSize = MemoryLayout<Float>.size

        // Frame count from the output side (Float32 samples, interleaved per buffer).
        var frames = 0
        var totalOut = 0
        for buffer in outBuffers {
            let n = Int(buffer.mNumberChannels)
            totalOut += n
            if frames == 0, n > 0 { frames = Int(buffer.mDataByteSize) / (n * sampleSize) }
        }
        frames = min(frames, capacity)
        guard frames > 0 else { return }

        // Gather the tap channels. They come after any input channels of the output device.
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        var totalIn = 0
        for buffer in inBuffers { totalIn += Int(buffer.mNumberChannels) }
        let firstTapChannel = max(0, totalIn - tapChannels)
        var channelBase = 0
        for buffer in inBuffers {
            let n = Int(buffer.mNumberChannels)
            defer { channelBase += n }
            guard n > 0, let raw = buffer.mData else { continue }
            let data = raw.assumingMemoryBound(to: Float.self)
            let available = min(frames, Int(buffer.mDataByteSize) / (n * sampleSize))
            for c in 0..<n {
                let channel = channelBase + c - firstTapChannel
                guard channel == 0 || channel == 1 else { continue }
                let dst = channel == 0 ? left : right
                for i in 0..<available { dst[i] = data[i * n + c] }
            }
        }
        if tapChannels == 1 { right.update(from: left, count: frames) }

        if let processor { processor.process(left: left, right: right, frames: frames) }

        // Write to the output device: L/R on the first two channels, silence elsewhere.
        channelBase = 0
        for buffer in outBuffers {
            let n = Int(buffer.mNumberChannels)
            defer { channelBase += n }
            guard n > 0, let raw = buffer.mData else { continue }
            let data = raw.assumingMemoryBound(to: Float.self)
            let available = min(frames, Int(buffer.mDataByteSize) / (n * sampleSize))
            for c in 0..<n {
                let channel = channelBase + c
                if totalOut == 1 {
                    for i in 0..<available { data[i] = 0.5 * (left[i] + right[i]) }
                } else if channel == 0 {
                    for i in 0..<available { data[i * n + c] = left[i] }
                } else if channel == 1 {
                    for i in 0..<available { data[i * n + c] = right[i] }
                } else {
                    for i in 0..<available { data[i * n + c] = 0 }
                }
            }
        }
    }
}
