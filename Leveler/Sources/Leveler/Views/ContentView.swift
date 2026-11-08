import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var engine: SystemAudioEngine
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header.riseIn(appeared, 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("Gleich laut.")
                    .font(.system(size: 38, weight: .heavy))
                    .tracking(-1.2)
                Text("Kein Zusammenzucken mehr bei lauten Szenen.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .riseIn(appeared, 1)

            if let problem {
                ProblemCard(problem: problem, engine: engine)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            PillToggle(isOn: $state.levelerOn).riseIn(appeared, 2)

            WaveCard(strength: $state.strength,
                     strengthLabel: state.strengthLabel,
                     history: state.history,
                     processor: engine.processor)
                .riseIn(appeared, 3)

            EQCard().riseIn(appeared, 4)

            footer.riseIn(appeared, 5)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(width: 460)
        .foregroundStyle(Theme.ink)
        .background(Theme.background)
        .environment(\.colorScheme, .light)
        .animation(Theme.spring, value: problem)
        .onAppear { appeared = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark()
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 22)
            Text("leveler")
                .font(.system(size: 16, weight: .heavy))
                .tracking(-0.2)
            Spacer()
            HStack(spacing: 6) {
                StatusDot(active: isActive)
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .contentTransition(.opacity)
            }
        }
    }

    private var isActive: Bool { engine.status == .running && state.levelerOn }

    private var statusText: String {
        switch engine.status {
        case .running: return state.levelerOn ? "Läuft im Hintergrund" : "Pausiert"
        case .starting: return "Startet…"
        case .stopped: return "Gestoppt"
        case .needsPermission, .failed, .unsupported: return "Kein Audiozugriff"
        }
    }

    private var problem: ProblemCard.Problem? {
        switch engine.status {
        case .needsPermission: return .permission
        case .unsupported: return .unsupported
        case .failed(let message): return .failed(message)
        default: return nil
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
            Text(engine.outputDeviceName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Toggle("Autostart", isOn: $state.launchAtLogin)
                .toggleStyle(.checkbox)
                .help("Leveler beim Anmelden automatisch starten")
            Button("Beenden") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .keyboardShortcut("q")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 4)
    }
}

private struct StatusDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(Theme.accent.opacity(0.6), lineWidth: 2)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(active ? Theme.accent : Theme.originalLine)
        }
        .frame(width: 7, height: 7)
        .onAppear { pulse = true }
    }
}

/// Shown when the system-audio permission is missing or the tap failed.
struct ProblemCard: View {
    enum Problem: Equatable {
        case permission
        case unsupported
        case failed(String)
    }

    let problem: Problem
    @ObservedObject var engine: SystemAudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 14, weight: .bold))
            }
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if problem != .unsupported {
                HStack(spacing: 8) {
                    if problem == .permission {
                        Button("Freigabe öffnen") {
                            if !NSWorkspace.shared.open(AudioCapturePermission.settingsURL) {
                                NSWorkspace.shared.open(AudioCapturePermission.fallbackSettingsURL)
                            }
                        }
                        .buttonStyle(ChipButtonStyle(filled: true))
                    }
                    Button("Erneut versuchen") { engine.requestPermissionAndStart() }
                        .buttonStyle(ChipButtonStyle(filled: problem != .permission))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var title: String {
        switch problem {
        case .permission: return "Zugriff auf den Systemton fehlt"
        case .unsupported: return "macOS zu alt"
        case .failed: return "Ton konnte nicht gestartet werden"
        }
    }

    private var message: String {
        switch problem {
        case .permission:
            return "Erlaube Leveler unter Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme › „Nur Systemaudioaufnahme“."
        case .unsupported:
            return "Leveler braucht macOS 14.2 (Sonoma) oder neuer."
        case .failed(let detail):
            return detail
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(filled ? Theme.accent : Theme.chip))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
