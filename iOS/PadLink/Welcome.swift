import SwiftUI

/// Shown until you tap "Got it" or the app connects to a PC for the first time.
struct WelcomeCard: View {
    let connected: Bool
    @AppStorage("welcomed") private var welcomed = false

    var body: some View {
        if !welcomed {
            Card(title: "Welcome") {
                Text("Three steps").font(.headline)
                step("1", "On your PC, download and run PadLink for Windows. The first time, it sets itself up: the controller driver, the firewall, and (if you want) starting at login.")
                Link(destination: URL(string: "https://github.com/ajhockey88/PadLink/releases/latest")!) {
                    Label("Get PadLink for Windows", systemImage: "arrow.down.circle")
                }
                step("2", "Plug your controller into this iPhone's USB-C port.")
                step("3", "This app finds your PC by itself. Allow Local Network access if iOS asks. If the PC gave you a pairing code, type it under PC below.")
                Button("Got it") { welcomed = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .onChange(of: connected) { isConnected in
                if isConnected { welcomed = true }
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.bg)
                .frame(width: 22, height: 22)
                .background(Theme.mint, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
        }
    }
}
