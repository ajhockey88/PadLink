import SwiftUI

struct ContentView: View {
    @StateObject private var link = PadLink()

    private var statusColor: Color {
        switch link.state {
        case .connected: return .green
        case .stopped: return .gray
        case .searching, .connecting, .reconnecting: return .orange
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                    Text(link.state.text).font(.headline)
                    Spacer()
                    if let pc = link.connectedPC, link.state != .stopped {
                        Text(pc).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Toggle("Find PC automatically", isOn: $link.auto)
                if link.auto {
                    pcList
                } else {
                    TextField("PC IP address", text: $link.manualHost)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }

                Text(link.controllerName ?? "No controller connected")
                Toggle("Swap A and B", isOn: $link.swapAB)
                Toggle("Swap X and Y", isOn: $link.swapXY)

                Button(link.running ? "Stop" : "Start") {
                    link.running ? link.stop() : link.start()
                }
                .buttonStyle(.borderedProminent)

                if link.running {
                    Button(link.testing ? "Stop latency test" : "Test latency") {
                        link.testing ? link.stopTest() : link.startTest()
                    }
                    .buttonStyle(.bordered)
                }
                if link.testing { LatencyView(rtt: link.rtt, history: link.history) }

                Text("\(link.packetsSent) packets sent")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .onAppear {
            // Start automatically every time the app opens.
            if !link.running && (link.auto || !link.manualHost.isEmpty) { link.start() }
        }
    }

    @ViewBuilder private var pcList: some View {
        if link.pcs.isEmpty {
            Text("Looking for PadLink receivers on your network…")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(link.pcs) { pc in
                    Button {
                        link.select(pc)
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(pc.id)
                            Spacer()
                            if link.connectedPC == pc.id { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
