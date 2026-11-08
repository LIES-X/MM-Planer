import AppKit
import SwiftUI

@main
struct LevelerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(engine: state.engine)
                .environmentObject(state)
        } label: {
            Image(systemName: state.isProcessing ? "waveform" : "waveform.slash")
                .accessibilityLabel("Leveler")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Runs in the background as a menu-bar app; start processing right away.
        AppState.shared.engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Removes the tap so the system's original audio is unmuted immediately.
        AppState.shared.engine.stop()
    }
}
