import SwiftUI

/// The big orange "Ausgleich ist an" switch. The black thumb springs across.
struct PillToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Theme.pillOff)

                Text(isOn ? "Ausgleich ist an" : "Ausgleich ist aus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: isOn ? .leading : .trailing)
                    .padding(.horizontal, 24)
                    .contentTransition(.opacity)

                Circle()
                    .fill(Theme.ink)
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: isOn ? "checkmark" : "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    )
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .padding(6)
            }
            .frame(height: 62)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Lautstärke-Ausgleich")
        .accessibilityValue(isOn ? "An" : "Aus")
        .accessibilityAddTraits(.isToggle)
    }
}
