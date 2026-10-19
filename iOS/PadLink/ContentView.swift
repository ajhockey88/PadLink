import SwiftUI

struct ContentView: View {
    @StateObject private var link = PadLink()
    @AppStorage("host") private var host = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(link.controllerName ?? "No controller connected")
            TextField("PC IP address", text: $host)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
            Toggle("Swap A and B", isOn: $link.swapAB)
            Toggle("Swap X and Y", isOn: $link.swapXY)
            Button(link.running ? "Stop" : "Start") {
                link.running ? link.stop() : link.start(host: host)
            }
            .buttonStyle(.borderedProminent)
            if link.running { LatencyView(rtt: link.rtt, history: link.history) }
            Text("\(link.packetsSent) packets sent")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            // Start automatically with the saved PC address every time the app opens.
            if !host.isEmpty && !link.running { link.start(host: host) }
        }
    }
}
