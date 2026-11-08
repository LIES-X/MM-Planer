import LevelerDSP
import SwiftUI

/// "Klang": presets plus the draggable 7-band EQ curve.
struct EQCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Klang").font(.system(size: 15, weight: .bold))
                Spacer()
                ForEach(AppState.presets) { preset in
                    Button(preset.name) { state.apply(preset) }
                        .buttonStyle(ChipButtonStyle(filled: state.preset == preset.name))
                        .animation(.easeInOut(duration: 0.2), value: state.preset)
                }
            }

            EQGraph(bands: state.bands,
                    onChange: { index, value in state.setBand(index, to: value) },
                    history: state.history)
                .contextMenu {
                    Button("Alle Bänder auf 0 dB") { state.resetEQ() }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .card()
    }
}

/// Smooth curve through the band values with handles, an animated spectrum behind,
/// and frequency / dB labels underneath. Drag anywhere to move the nearest band.
struct EQGraph: View {
    let bands: [Double]
    let onChange: (Int, Double) -> Void
    let history: LevelHistory

    @State private var dragIndex: Int?

    private let graphHeight: CGFloat = 156
    private let labelHeight: CGFloat = 36
    static let sidePad: CGFloat = 24
    static let vPad: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                SpectrumView(history: history)
                    .frame(width: width - 2 * Self.sidePad, height: graphHeight)
                    .offset(x: Self.sidePad)

                GridLines()
                    .frame(width: width, height: graphHeight)

                EQCurveShape(values: EQVector(bands), closed: true)
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: width, height: graphHeight)

                EQCurveShape(values: EQVector(bands), closed: false)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: width, height: graphHeight)

                ForEach(bands.indices, id: \.self) { i in
                    let point = Self.point(i, value: bands[i], count: bands.count, width: width, height: graphHeight)
                    let active = dragIndex == i
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 3))
                        .frame(width: active ? 22 : 18, height: active ? 22 : 18)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .position(point)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)

                    VStack(spacing: 2) {
                        Text(AppState.bandLabels[i])
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                        Text(Self.dbText(bands[i]))
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .frame(width: 60)
                    .position(x: point.x, y: graphHeight + 8 + labelHeight / 2)
                }
            }
            .frame(width: width, height: graphHeight + 8 + labelHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let index = dragIndex ?? Self.nearestBand(to: drag.startLocation.x, count: bands.count, width: width)
                        if dragIndex == nil { dragIndex = index }
                        onChange(index, Self.value(atY: drag.location.y, height: graphHeight))
                    }
                    .onEnded { _ in dragIndex = nil }
            )
        }
        .frame(height: graphHeight + 8 + labelHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equalizer")
        .accessibilityValue(zip(AppState.bandLabels, bands).map { "\($0) Hertz \(Self.dbText($1)) dB" }.joined(separator: ", "))
    }

    static func dbText(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    static func point(_ i: Int, value: Double, count: Int, width: CGFloat, height: CGFloat) -> CGPoint {
        let step = (width - 2 * sidePad) / CGFloat(max(count - 1, 1))
        let mid = height / 2
        let scale = (height / 2 - vPad) / 12
        return CGPoint(x: sidePad + CGFloat(i) * step, y: mid - CGFloat(value) * scale)
    }

    static func nearestBand(to x: CGFloat, count: Int, width: CGFloat) -> Int {
        let step = (width - 2 * sidePad) / CGFloat(max(count - 1, 1))
        let i = Int(((x - sidePad) / step).rounded())
        return min(max(i, 0), count - 1)
    }

    static func value(atY y: CGFloat, height: CGFloat) -> Double {
        let mid = height / 2
        let scale = (height / 2 - vPad) / 12
        return Double((mid - y) / scale)
    }
}

/// Dashed ±12 dB lines, a solid 0 dB line and their labels.
private struct GridLines: View {
    var body: some View {
        Canvas { context, size in
            let left = EQGraph.sidePad, right = size.width - EQGraph.sidePad
            let top = EQGraph.vPad, mid = size.height / 2, bottom = size.height - EQGraph.vPad
            for (y, dashed) in [(top, true), (mid, false), (bottom, true)] {
                var line = Path()
                line.move(to: CGPoint(x: left, y: y))
                line.addLine(to: CGPoint(x: right, y: y))
                context.stroke(line,
                               with: .color(dashed ? Theme.grid : Theme.zeroLine),
                               style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 5] : []))
            }
            for (text, y) in [("+12", top), ("0", mid), ("−12", bottom)] {
                context.draw(Text(text).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.secondary),
                             at: CGPoint(x: left - 4, y: y), anchor: .trailing)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Soft bars dancing behind the curve; they get taller when audio is playing.
private struct SpectrumView: View {
    let history: LevelHistory

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = CGFloat(history.latestOutput)
                let count = 36
                let gap: CGFloat = 4
                let barWidth = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                let speeds: [Double] = [5.2, 7.4, 4.1, 8.8, 6.3, 3.7]
                for i in 0..<count {
                    let osc = 0.5 + 0.5 * sin(t * speeds[i % speeds.count] + Double(i) * 1.7)
                    let h = size.height * (0.10 + 0.72 * CGFloat(osc) * (0.28 + 0.72 * level))
                    let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: size.height - h, width: barWidth, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Theme.accent.opacity(0.10)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Catmull-Rom curve through the band values. Animatable, so presets morph smoothly.
struct EQCurveShape: Shape {
    var values: EQVector
    var closed: Bool

    var animatableData: EQVector {
        get { values }
        set { values = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let v = values.values
        guard v.count > 1 else { return Path() }
        let pts = v.indices.map { EQGraph.point($0, value: v[$0], count: v.count, width: rect.width, height: rect.height) }
        var path = Path()
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed {
            let mid = rect.height / 2
            path.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: mid))
            path.addLine(to: CGPoint(x: pts[0].x, y: mid))
            path.closeSubpath()
        }
        return path
    }
}

/// Fixed-size vector of band gains so SwiftUI can interpolate the whole curve.
struct EQVector: VectorArithmetic {
    var values: [Double]

    init(_ values: [Double]) { self.values = values }

    static var zero: EQVector { EQVector([Double](repeating: 0, count: 7)) }

    static func + (lhs: EQVector, rhs: EQVector) -> EQVector {
        EQVector(combine(lhs.values, rhs.values, +))
    }

    static func - (lhs: EQVector, rhs: EQVector) -> EQVector {
        EQVector(combine(lhs.values, rhs.values, -))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    private static func combine(_ a: [Double], _ b: [Double], _ op: (Double, Double) -> Double) -> [Double] {
        let n = max(a.count, b.count)
        return (0..<n).map { op($0 < a.count ? a[$0] : 0, $0 < b.count ? b[$0] : 0) }
    }
}
