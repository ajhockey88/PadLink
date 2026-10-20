import SwiftUI

/// Summary of one benchmark run: round-trip times to the PC, in milliseconds.
struct BenchmarkResult: Codable, Equatable {
    var average: Double
    var median: Double
    var p95: Double
    var minimum: Double
    var maximum: Double
    var jitter: Double  // average change between consecutive replies
    var loss: Double    // percent of pings with no reply
    var sent: Int
    var received: Int
    var date: Date

    init(rtts: [Double], sent: Int) {
        let sorted = rtts.sorted()
        let n = sorted.count
        self.sent = sent
        received = n
        average = n == 0 ? 0 : rtts.reduce(0, +) / Double(n)
        median = n == 0 ? 0 : (n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2)
        p95 = n == 0 ? 0 : sorted[max(0, Int((Double(n) * 0.95).rounded(.up)) - 1)]
        minimum = sorted.first ?? 0
        maximum = sorted.last ?? 0
        jitter = n > 1 ? zip(rtts, rtts.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(n - 1) : 0
        loss = sent > 0 ? Double(sent - n) / Double(sent) * 100 : 0
        date = Date()
    }

    var rating: String {
        average < 8 ? "Excellent" : average < 15 ? "Good" : average < 30 ? "Fair" : "Poor"
    }

    var ratingColor: Color {
        average < 15 ? Theme.mint : average < 30 ? Theme.amber : Theme.red
    }
}

enum BenchmarkState: Equatable {
    case idle
    case running(Double)  // 0...1
    case done(BenchmarkResult)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Progress, then the results, of a 10-second benchmark.
struct BenchmarkView: View {
    @ObservedObject var link: PadLink

    var body: some View {
        switch link.benchmark {
        case .idle:
            EmptyView()
        case .running(let progress):
            Card(title: "Benchmark") {
                HStack {
                    Text("Measuring…").font(.headline)
                    Spacer()
                    Text("\(Int(progress * 100))%").foregroundStyle(Theme.muted).monospacedDigit()
                }
                ProgressView(value: progress).tint(Theme.mint)
                Text("200 pings over about 10 seconds. Keep playing or leave the controller alone; it does not affect the result.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Button("Cancel") { link.cancelBenchmark() }
                    .font(.footnote)
            }
        case .failed(let message):
            Card(title: "Benchmark") {
                Text(message).foregroundStyle(Theme.red)
                Button("Try again") { link.startBenchmark() }
                    .font(.footnote)
            }
        case .done(let r):
            Card(title: "Benchmark") {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.1f ms", r.average))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(r.ratingColor)
                    Text("average").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(r.rating)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(r.ratingColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(r.ratingColor)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
                    stat("median", String(format: "%.1f", r.median))
                    stat("95th pct", String(format: "%.1f", r.p95))
                    stat("jitter", String(format: "%.1f", r.jitter))
                    stat("min", String(format: "%.1f", r.minimum))
                    stat("max", String(format: "%.1f", r.maximum))
                    stat("lost", String(format: "%.1f%%", r.loss))
                }
                Text("\(r.received) of \(r.sent) replies. Round trip phone → PC → phone, so one way is about half. Excludes controller USB polling.")
                    .font(.caption2).foregroundStyle(Theme.muted)
                if let prev = link.previousBenchmark {
                    let delta = r.average - prev.average
                    Text(String(format: "Previous run: %.1f ms (%@%.1f ms)", prev.average, delta <= 0 ? "" : "+", delta))
                        .font(.footnote)
                        .foregroundStyle(delta <= 0 ? Theme.mint : Theme.amber)
                }
                Button("Run again") { link.startBenchmark() }
                    .font(.footnote)
            }
        }
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .rounded).monospacedDigit())
            Text(name).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
