import Foundation
import GameController
import Network
import AVFoundation
import UIKit

/// Reads a wired controller via GameController and streams its state over UDP.
final class PadLink: ObservableObject {
    static let port: NWEndpoint.Port = 26760
    static let heartbeat: TimeInterval = 0.004  // resend at 250 Hz so a lost packet self-heals

    @Published var controllerName: String?
    @Published var running = false
    @Published var packetsSent = 0

    // Swap face buttons (e.g. Nintendo-style layout). Read on the network queue, written from the UI.
    @Published var swapAB = UserDefaults.standard.bool(forKey: "swapAB") {
        didSet { UserDefaults.standard.set(swapAB, forKey: "swapAB"); layout = (swapAB, swapXY) }
    }
    @Published var swapXY = UserDefaults.standard.bool(forKey: "swapXY") {
        didSet { UserDefaults.standard.set(swapXY, forKey: "swapXY"); layout = (swapAB, swapXY) }
    }
    private var layout = (UserDefaults.standard.bool(forKey: "swapAB"), UserDefaults.standard.bool(forKey: "swapXY"))

    private let queue = DispatchQueue(label: "padlink.net", qos: .userInteractive)
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var seq: UInt16 = 0
    private var pad: GCExtendedGamepad?
    private var current: GCController?
    private var attached: [GCController] = []
    private var host = ""
    private let audio = AVAudioEngine()

    init() {
        // Keep delivering controller input when the app is not frontmost.
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.detach(c) }
        }
        GCController.controllers().forEach(attach)
    }

    /// Listens to every connected controller; whichever you touch last becomes the active one.
    private func attach(_ c: GCController) {
        guard let gp = c.extendedGamepad else { return }
        if !attached.contains(where: { $0 === c }) { attached.append(c) }
        gp.valueChangedHandler = { [weak self] g, _ in self?.activate(g.controller) }
        if current == nil { activate(c) }
        refreshName()
    }

    private func detach(_ c: GCController) {
        attached.removeAll { $0 === c }
        c.extendedGamepad?.valueChangedHandler = nil
        if current === c {
            current = nil
            let next = attached.first
            if let next { activate(next) } else { queue.async { self.pad = nil } }
        }
        refreshName()
    }

    private func activate(_ c: GCController?) {
        guard let c, let gp = c.extendedGamepad else { return }
        if current !== c {
            current = c
            queue.async { self.pad = gp }
            refreshName()
        }
        send()
    }

    private func refreshName() {
        let n = attached.count
        controllerName = current.map { ($0.vendorName ?? "Controller") + (n > 1 ? " (+\(n - 1) more)" : "") }
    }

    /// A silent audio session keeps the app running when you switch apps or lock the phone.
    private func startKeepAlive() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let format = audio.outputNode.inputFormat(forBus: 0)
            let silence = AVAudioSourceNode { _, _, _, buffers in
                for b in UnsafeMutableAudioBufferListPointer(buffers) { memset(b.mData, 0, Int(b.mDataByteSize)) }
                return noErr
            }
            audio.attach(silence)
            audio.connect(silence, to: audio.mainMixerNode, format: format)
            try audio.start()
        } catch {}
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private func stopKeepAlive() {
        audio.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
    }

    func start(host: String) {
        guard !host.isEmpty else { return }
        self.host = host
        connect()
        running = true
        startKeepAlive()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.heartbeat)
        t.setEventHandler { [weak self] in self?.send() }
        t.resume()
        timer = t
    }

    private func connect() {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        let conn = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: params)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            // Network changes (Wi-Fi roam, app resume) can fail the socket; rebuild it.
            guard let self, let conn, self.connection === conn else { return }
            if case .failed = state { conn.cancel(); self.connect() }
        }
        conn.start(queue: queue)
        connection?.cancel()
        connection = conn
    }

    func stop() {
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        running = false
        stopKeepAlive()
    }

    private func send() {
        queue.async { [self] in
            guard let conn = connection, let pad else { return }
            let data = Self.encode(pad, seq: seq, swapAB: layout.0, swapXY: layout.1)
            seq &+= 1
            conn.send(content: data, completion: .idempotent)
            DispatchQueue.main.async { self.packetsSent += 1 }
        }
    }

    static func encode(_ p: GCExtendedGamepad, seq: UInt16, swapAB: Bool, swapXY: Bool) -> Data {
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
        set(p.buttonA.isPressed, swapAB ? 0x2000 : 0x1000); set(p.buttonB.isPressed, swapAB ? 0x1000 : 0x2000)
        set(p.buttonX.isPressed, swapXY ? 0x8000 : 0x4000); set(p.buttonY.isPressed, swapXY ? 0x4000 : 0x8000)

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
