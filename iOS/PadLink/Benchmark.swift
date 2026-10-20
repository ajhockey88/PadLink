import SwiftUI

/// Network half of a benchmark: round-trip times to the PC, in milliseconds.
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
}

/// Controller half: how often the controller reports input while you move a stick.
struct ControllerStats: Codable, Equatable {
    var name: String
    var events: Int
    var avgInterval: Double  // ms between consecutive input reports
    var p95Interval: Double

    var rateHz: Double { avgInterval > 0 ? 1000 / avgInterval : 0 }
    /// A press lands at a random moment between reports, so it waits half a gap on average.
    var inputDelay: Double { avgInterval / 2 }

    /// `times` are uptime nanoseconds of each input event from one controller.
    static func make(name: String, times: [UInt64]) -> ControllerStats? {
        var gaps: [Double] = []
        for (a, b) in zip(times, times.dropFirst()) where b > a {
            let ms = Double(b - a) / 1_000_000
            // Under 0.3 ms is the same report delivered as two callbacks; over 50 ms is a pause.
            if ms >= 0.3 && ms < 50 { gaps.append(ms) }
        }
        guard gaps.count >= 20 else { return nil }
        let sorted = gaps.sorted()
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        let p95 = sorted[max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return ControllerStats(name: name, events: times.count, avgInterval: avg, p95Interval: p95)
    }
}

/// One benchmark: network numbers plus (if you moved a stick) the controller's.
struct BenchmarkRun: Codable, Equatable, Identifiable {
    var id = UUID()
    var network: BenchmarkResult
    var controller: ControllerStats?

    var oneWay: Double { network.average / 2 }
    /// Controller wait plus network one way. Excludes the PC, the game and the display.
    var total: Double? { controller.map { $0.inputDelay + oneWay } }

    static func rating(_ ms: Double) -> String {
        ms < 10 ? "Excellent" : ms < 20 ? "Good" : ms < 40 ? "Fair" : "Poor"
    }

    static func color(_ ms: Double) -> Color {
        ms < 20 ? Theme.mint : ms < 40 ? Theme.amber : Theme.red
    }
}

/// Everything saved for one controller model, newest run last.
struct SavedController: Codable, Equatable, Identifiable {
    var name: String
    var runs: [BenchmarkRun]

    var id: String { name }
    var latest: BenchmarkRun? { runs.last }
    var best: Double? { runs.compactMap { $0.total }.min() }
}

enum BenchmarkState: Equatable {
    case idle
    case running(Double)  // 0...1
    case done(BenchmarkRun)
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
                Text("Move the left stick in circles, or mash buttons, for the whole 10 seconds. That is how the controller is measured.")
                    .font(.footnote).foregroundStyle(Theme.text)
                Text("Use the controller you want to rate. If several are plugged in, the one you move is saved.")
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
        case .done(let run):
            result(run)
        }
    }

    private func result(_ run: BenchmarkRun) -> some View {
        let n = run.network
        return Card(title: "Benchmark") {
            if let c = run.controller, let total = run.total {
                Text(c.name).font(.subheadline.weight(.semibold))
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.1f ms", total))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(BenchmarkRun.color(total))
                    Text("input latency").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(BenchmarkRun.rating(total))
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(BenchmarkRun.color(total).opacity(0.18), in: Capsule())
                        .foregroundStyle(BenchmarkRun.color(total))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
                    stat("report rate", String(format: "%.0f Hz", c.rateHz))
                    stat("controller", String(format: "%.1f ms", c.inputDelay))
                    stat("network", String(format: "%.1f ms", run.oneWay))
                }
                Text("Controller = half the average gap between its input reports (\(String(format: "%.1f", c.avgInterval)) ms). Network = half the round trip. The PC, the game and your display add more.")
                    .font(.caption2).foregroundStyle(Theme.muted)
                if let prev = link.previousRun, let before = prev.total {
                    let delta = total - before
                    Text(String(format: "Previous run on this controller: %.1f ms (%@%.1f ms)", before, delta <= 0 ? "" : "+", delta))
                        .font(.footnote)
                        .foregroundStyle(delta <= 0 ? Theme.mint : Theme.amber)
                }
            } else {
                Text("No controller input detected")
                    .font(.headline).foregroundStyle(Theme.amber)
                Text("Network only. Run it again and move a stick or press buttons continuously so the controller can be measured and saved.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Divider().overlay(Theme.line)
            HStack(alignment: .firstTextBaseline) {
                Text("Network round trip").foregroundStyle(Theme.muted)
                Spacer()
                Text(String(format: "%.1f ms avg", n.average)).monospacedDigit()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
                stat("median", String(format: "%.1f", n.median))
                stat("95th pct", String(format: "%.1f", n.p95))
                stat("jitter", String(format: "%.1f", n.jitter))
                stat("min", String(format: "%.1f", n.minimum))
                stat("max", String(format: "%.1f", n.maximum))
                stat("lost", String(format: "%.1f%%", n.loss))
            }
            Text("\(n.received) of \(n.sent) replies.")
                .font(.caption2).foregroundStyle(Theme.muted)
            Button("Run again") { link.startBenchmark() }
                .font(.footnote)
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

/// Saved benchmark results, one row per controller model, fastest first.
struct SavedControllersView: View {
    @ObservedObject var link: PadLink

    var body: some View {
        if link.savedControllers.isEmpty {
            EmptyView()
        } else {
            Card(title: "Saved controllers") {
                ForEach(link.sortedControllers) { saved in
                    row(saved)
                    if saved.id != link.sortedControllers.last?.id { Divider().overlay(Theme.line) }
                }
                Button("Clear all results") { link.clearSaved() }
                    .font(.footnote)
                    .foregroundStyle(Theme.red)
            }
        }
    }

    private func row(_ saved: SavedController) -> some View {
        let latest = saved.latest
        let total = latest?.total ?? 0
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.name)
                Text(detail(saved))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(String(format: "%.1f ms", total))
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(BenchmarkRun.color(total))
            Button {
                link.removeController(saved.name)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(saved.name)")
        }
    }

    private func detail(_ saved: SavedController) -> String {
        let runs = saved.runs.count
        let rate = saved.latest?.controller.map { String(format: "%.0f Hz", $0.rateHz) } ?? "-"
        let best = saved.best.map { String(format: "best %.1f ms", $0) } ?? ""
        return "\(rate) · \(runs) run\(runs == 1 ? "" : "s") · \(best)"
    }
}
