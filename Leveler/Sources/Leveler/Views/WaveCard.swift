import LevelerDSP
import SwiftUI

/// "Original" vs. "Mit Leveler": a scrolling wave whose height follows the real
/// input and output loudness, plus the strength slider.
struct WaveCard: View {
    @Binding var strength: Double
    let strengthLabel: String
    let history: LevelHistory
    let processor: AudioProcessor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                legend("Original", color: Theme.originalLine, height: 2)
                legend("Mit Leveler", color: Theme.accent, height: 4)
            }
            .padding(.horizontal, 20)

            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                Canvas { context, size in
                    history.tick(now: timeline.date, processor: processor)
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    context.stroke(wave(history.input, size: size, time: t),
                                   with: .color(Theme.originalLine), lineWidth: 1.5)
                    context.stroke(wave(history.output, size: size, time: t),
                                   with: .color(Theme.accent),
                                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 76)
            .padding(.horizontal, 20)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stärke")
                    Spacer()
                    Text(strengthLabel)
                        .foregroundStyle(Theme.secondary)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: strengthLabel)
                }
                .font(.system(size: 13, weight: .semibold))
                Slider(value: $strength, in: 0...100, step: 5)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .accessibilityLabel("Stärke")
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 16)
        .padding(.bottom, 14)
        .card()
    }

    private func legend(_ text: String, color: Color, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: height / 2).fill(color).frame(width: 14, height: height)
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.secondary)
    }

    /// Sine carrier scrolling left, its height shaped by the loudness history
    /// (oldest value on the left, newest on the right).
    private func wave(_ levels: [Float], size: CGSize, time: Double) -> Path {
        var path = Path()
        let mid = size.height / 2
        let amplitude = size.height / 2 - 3
        let count = levels.count
        let phase = time * 7
        var x: CGFloat = 0
        while x <= size.width {
            let pos = Double(x / max(size.width, 1)) * Double(count - 1)
            let i = min(Int(pos), count - 2)
            let frac = Float(pos - Double(i))
            let env = CGFloat(levels[i] + (levels[i + 1] - levels[i]) * frac)
            let shaped = max(env, 0.035)
            let carrier = sin(Double(x) * 0.15 - phase) * (0.78 + 0.22 * sin(Double(x) * 0.043 + phase * 0.31))
            let y = mid + shaped * amplitude * CGFloat(carrier)
            if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            x += 2
        }
        return path
    }
}
