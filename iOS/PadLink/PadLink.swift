import Foundation
import GameController
import Network

/// Reads a wired controller via GameController and streams its state over UDP.
final class PadLink: ObservableObject {
    static let port: NWEndpoint.Port = 26760
    static let heartbeat: TimeInterval = 0.004  // resend at 250 Hz so a lost packet self-heals

    @Published var controllerName: String?
    @Published var running = false
    @Published var packetsSent = 0

    private let queue = DispatchQueue(label: "padlink.net", qos: .userInteractive)
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var seq: UInt16 = 0
    private var pad: GCExtendedGamepad?

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachFirstController()
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachFirstController()
        }
        attachFirstController()
    }

    private func attachFirstController() {
        let c = GCController.controllers().first { $0.extendedGamepad != nil }
        pad = c?.extendedGamepad
        controllerName = c?.vendorName ?? c.map { _ in "Controller" }
        pad?.valueChangedHandler = { [weak self] _, _ in self?.send() }
    }

    func start(host: String) {
        guard !host.isEmpty else { return }
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        let conn = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: params)
        conn.start(queue: queue)
        connection = conn
        running = true

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.heartbeat)
        t.setEventHandler { [weak self] in self?.send() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        running = false
    }

    private func send() {
        queue.async { [self] in
            guard let conn = connection, let pad else { return }
            let data = Self.encode(pad, seq: seq)
            seq &+= 1
            conn.send(content: data, completion: .idempotent)
            DispatchQueue.main.async { self.packetsSent += 1 }
        }
    }

    static func encode(_ p: GCExtendedGamepad, seq: UInt16) -> Data {
        var b: UInt16 = 0
        func set(_ on: Bool, _ mask: UInt16) { if on { b |= mask } }
        set(p.dpad.up.isPressed, 0x1); set(p.dpad.down.isPressed, 0x2)
        set(p.dpad.left.isPressed, 0x4); set(p.dpad.right.isPressed, 0x8)
        set(p.buttonMenu.isPressed, 0x10)
        set(p.buttonOptions?.isPressed ?? false, 0x20)
        set(p.leftThumbstickButton?.isPressed ?? false, 0x40)
        set(p.rightThumbstickButton?.isPressed ?? false, 0x80)
        set(p.leftShoulder.isPressed, 0x100); set(p.rightShoulder.isPressed, 0x200)
        set(p.buttonHome?.isPressed ?? false, 0x400)
        set(p.buttonA.isPressed, 0x1000); set(p.buttonB.isPressed, 0x2000)
        set(p.buttonX.isPressed, 0x4000); set(p.buttonY.isPressed, 0x8000)

        func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        func trig(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }

        var d = Data(capacity: 16)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt16(0x504C)); put(seq); put(b)
        put(trig(p.leftTrigger.value)); put(trig(p.rightTrigger.value))
        put(axis(p.leftThumbstick.xAxis.value)); put(axis(p.leftThumbstick.yAxis.value))
        put(axis(p.rightThumbstick.xAxis.value)); put(axis(p.rightThumbstick.yAxis.value))
        return d
    }
}
