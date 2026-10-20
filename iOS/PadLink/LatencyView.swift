import SwiftUI

/// Live round-trip latency to the PC receiver: big number, stats and a scrolling graph.
struct LatencyView: View {
    let rtt: Double?
    let history: [Double]

    private var good: [Double] { history.filter { $0 >= 0 } }
    private var avg: Double { good.isEmpty ? 0 : good.reduce(0, +) / Double(good.count) }
    private var jitter: Double {
        guard good.count > 1 else { return 0 }
        return zip(good, good.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(good.count - 1)
    }
    private var loss: Double {
        history.isEmpty ? 0 : Double(history.filter { $0 < 0 }.count) / Double(history.count) * 100
    }

    private func color(_ ms: Double) -> Color { ms < 8 ? Theme.mint : ms < 20 ? Theme.amber : Theme.red }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(rtt.map { String(format: "%.1f ms", $0) } ?? "No reply")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(rtt.map(color) ?? Theme.red)
                Spacer()
                Text(rtt.map { String(format: "~%.1f ms one-way", $0 / 2) } ?? "check PC receiver")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Graph(history: history, color: color)
                .frame(height: 70)
            HStack {
                stat("avg", String(format: "%.1f", avg))
                stat("min", String(format: "%.1f", good.min() ?? 0))
                stat("max", String(format: "%.1f", good.max() ?? 0))
                stat("jitter", String(format: "%.1f", jitter))
                stat("lost", String(format: "%.0f%%", loss))
            }
            Text("Round trip phone \u{2192} PC \u{2192} phone. Excludes controller USB polling.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack { Text(value).font(.subheadline.monospacedDigit()); Text(name).font(.caption2).foregroundStyle(Theme.muted) }
            .frame(maxWidth: .infinity)
    }

    private struct Graph: View {
        let history: [Double]
        let color: (Double) -> Color

        var body: some View {
            GeometryReader { geo in
                let ceiling = max(20, (history.max() ?? 0) * 1.2)
                let step = geo.size.width / CGFloat(max(PadLink.historyLength - 1, 1))
                let offset = CGFloat(PadLink.historyLength - history.count) * step
                ZStack(alignment: .bottomLeading) {
                    Path { p in
                        for y in [0.25, 0.5, 0.75] as [CGFloat] {
                            p.move(to: CGPoint(x: 0, y: geo.size.height * y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * y))
                        }
                    }.stroke(Theme.line, lineWidth: 0.5)
                    ForEach(Array(history.enumerated()), id: \.offset) { i, v in
                        let x = offset + CGFloat(i) * step
                        if v < 0 {
                            Rectangle().fill(Theme.red.opacity(0.7)).frame(width: max(step, 2), height: geo.size.height)
                                .position(x: x, y: geo.size.height / 2)
                        } else {
                            let h = max(2, CGFloat(v / ceiling) * geo.size.height)
                            Rectangle().fill(color(v)).frame(width: max(step - 0.5, 1.5), height: h)
                                .position(x: x, y: geo.size.height - h / 2)
                        }
                    }
                    Text("\(Int(ceiling)) ms").font(.system(size: 9)).foregroundStyle(Theme.muted)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }
}
