import Foundation

/// Checks / requests the "System Audio Recording" permission.
///
/// macOS has no public API to query this permission, so – like other system-audio
/// tools – we use the TCC framework's preflight/request functions if available and
/// otherwise fall back to "unknown" (macOS then asks on first use of the tap).
enum AudioCapturePermission {
    enum Status { case granted, denied, unknown }

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunc: PreflightFunc? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFunc.self)
    }()

    private static let requestFunc: RequestFunc? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFunc.self)
    }()

    static var status: Status {
        guard let preflightFunc else { return .unknown }
        switch preflightFunc(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Asks the user (system dialog). Calls back on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestFunc else {
            DispatchQueue.main.async { completion(true) } // let Core Audio prompt on first use
            return
        }
        requestFunc(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    static let fallbackSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
