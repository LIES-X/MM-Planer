import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus

    var errorDescription: String? { "\(message) (Fehler \(status))" }
}

@discardableResult
func check(_ status: OSStatus, _ message: @autoclosure () -> String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(message: message(), status: status) }
    return status
}

enum CoreAudioHelpers {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &device),
                  "Standard-Ausgabegerät nicht gefunden")
        guard device != unknown else { throw CoreAudioError(message: "Kein Ausgabegerät aktiv", status: -1) }
        return device
    }

    static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value),
                  "Geräteeigenschaft nicht lesbar")
        guard let str = value?.takeRetainedValue() else {
            throw CoreAudioError(message: "Geräteeigenschaft leer", status: -1)
        }
        return str as String
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        try string(kAudioDevicePropertyDeviceUID, of: device)
    }

    static func deviceName(_ device: AudioObjectID) -> String? {
        try? string(kAudioObjectPropertyName, of: device)
    }

    static func nominalSampleRate(_ device: AudioObjectID) throws -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate),
                  "Abtastrate nicht lesbar")
        return rate
    }

    /// The Core Audio process object of a PID, or `unknown` if the process has none (yet).
    static func processObject(for pid: pid_t) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pidValue,
                                                &size, &object)
        return status == noErr ? object : unknown
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format),
                  "Tap-Format nicht lesbar")
        return format
    }
}
