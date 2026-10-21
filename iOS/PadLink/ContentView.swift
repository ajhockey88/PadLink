import SwiftUI

struct ContentView: View {
    @StateObject private var link = PadLink()

    private var statusColor: Color {
        switch link.state {
        case .connected: return Theme.mint
        case .stopped: return Theme.muted
        case .searching, .connecting, .reconnecting: return Theme.amber
        case .needsPairing: return Theme.red
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    WelcomeCard(connected: link.state == .connected)
                    statusCard
                    pcCard
                    controllerCard
                    tuningCard
                    actions
                    if link.testing { LatencyView(rtt: link.rtt, history: link.history) }
                    BenchmarkView(link: link)
                    SavedControllersView(link: link)
                    Text("\(link.packetsSent) packets sent")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.mint)
        .preferredColorScheme(.dark)
        .onAppear {
            // Start automatically every time the app opens.
            if !link.running && (link.auto || !link.manualHost.isEmpty) { link.start() }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            LogoMark(size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text("PadLink")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Wired controller to your PC")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 10) {
                StatusDot(color: statusColor, pulsing: link.state != .connected && link.state != .stopped)
                Text(link.state.text).font(.headline)
                Spacer()
                if let pc = link.connectedPC, link.state != .stopped {
                    Text(pc).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }

    private var pcCard: some View {
        Card(title: "PC") {
            Toggle("Find PC automatically", isOn: $link.auto)
            if link.auto {
                pcList
            } else {
                TextField("PC IP address", text: $link.manualHost)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            pairingField
        }
    }

    private var pairingField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Pairing code (only if the PC asks)", text: $link.pairingCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(12)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if link.state == .needsPairing {
                Text(link.pairingCode.isEmpty
                     ? "This PC needs a pairing code. Right-click PadLink in the PC tray > Pairing > Show pairing code."
                     : "That code does not match this PC. Check it in the PC tray > Pairing > Show pairing code.")
                    .font(.footnote)
                    .foregroundStyle(Theme.red)
            }
        }
    }

    @ViewBuilder private var pcList: some View {
        if link.pcs.isEmpty {
            Text("Looking for PadLink receivers on your network…")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        } else {
            VStack(spacing: 8) {
                ForEach(link.pcs) { pc in
                    let selected = link.connectedPC == pc.id
                    Button { link.select(pc) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                            Text(pc.id)
                            Spacer()
                            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.mint) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(selected ? Theme.mint.opacity(0.12) : Theme.bg,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? Theme.mint : Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var controllerCard: some View {
        Card(title: "Controller") {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(link.controllerName == nil ? Theme.muted : Theme.mint)
                Text(link.controllerName ?? "No controller connected")
                    .foregroundStyle(link.controllerName == nil ? Theme.muted : Theme.text)
            }
            Divider().overlay(Theme.line)
            Toggle("Swap A and B", isOn: $link.swapAB)
            Toggle("Swap X and Y", isOn: $link.swapXY)
        }
    }

    private var tuningCard: some View {
        Card(title: "Tuning") {
            slider("Stick dead zone", value: $link.stickDeadZone)
            slider("Trigger dead zone", value: $link.triggerDeadZone)
            if link.stickDeadZone > 0 || link.triggerDeadZone > 0 {
                Button("Reset to 0%") { link.resetTuning() }
                    .font(.footnote)
            }
            Divider().overlay(Theme.line)
            Text("Send rate")
            Picker("Send rate", selection: $link.sendRate) {
                Text("250 Hz").tag(250)
                Text("500 Hz").tag(500)
                Text("1000 Hz").tag(1000)
            }
            .pickerStyle(.segmented)
            Text("How often your controller's current state is re-sent even if nothing changed. Changes are always sent immediately. Higher recovers from a dropped packet sooner but uses more battery and Wi-Fi.")
                .font(.caption2)
                .foregroundStyle(Theme.muted)
        }
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0...0.3, step: 0.01)
                .accessibilityLabel(title)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if link.running {
                Button("Stop") { link.stop() }
                    .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.red))
                Button(link.testing ? "Stop latency test" : "Test latency") {
                    link.testing ? link.stopTest() : link.startTest()
                }
                .buttonStyle(PrimaryButtonStyle(filled: false))
                Button(link.benchmark.isRunning ? "Benchmarking…" : "Run benchmark") { link.startBenchmark() }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
                    .disabled(link.benchmark.isRunning || link.state != .connected)
                    .opacity(link.state == .connected ? 1 : 0.5)
            } else {
                Button("Start") { link.start() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// Status light; pulses while the link is searching or reconnecting.
private struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .shadow(color: color.opacity(0.7), radius: 4)
            .opacity(pulsing && dim ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
