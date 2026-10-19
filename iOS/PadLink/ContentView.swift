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
            Button(link.running ? "Stop" : "Start") {
                link.running ? link.stop() : link.start(host: host)
            }
            .buttonStyle(.borderedProminent)
            Text("\(link.packetsSent) packets sent")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }
}
