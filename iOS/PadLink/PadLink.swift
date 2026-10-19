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

    // Latency (round trip to the PC receiver), updated ~5x per second.
    @Published var rtt: Double?               // latest, milliseconds
    @Published var history: [Double] = []     // recent samples, -1 = lost
    private var pingSeq: UInt16 = 0
    private var pingTimer: DispatchSourceTimer?
    private var lastReply = DispatchTime.now().uptimeNanoseconds
    static let historyLength = 120

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
    private var pads: [GCExtendedGamepad] = []
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

    /// Every connected controller feeds the same virtual pad; their inputs are merged.
    private func attach(_ c: GCController) {
        guard let gp = c.extendedGamepad else { return }
        if !attached.contains(where: { $0 === c }) { attached.append(c) }
        gp.valueChangedHandler = { [weak self] _, _ in self?.send() }
        syncPads()
    }

    private func detach(_ c: GCController) {
        attached.removeAll { $0 === c }
        c.extendedGamepad?.valueChangedHandler = nil
        syncPads()
    }

    private func syncPads() {
        let gps = attached.compactMap { $0.extendedGamepad }
        queue.async { self.pads = gps }
        let n = attached.count
        controllerName = n == 0 ? nil : (attached[0].vendorName ?? "Controller") + (n > 1 ? " (+\(n - 1) more)" : "")
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

        let p = DispatchSource.makeTimerSource(queue: queue)
        p.schedule(deadline: .now(), repeating: 0.2)
        p.setEventHandler { [weak self] in self?.ping() }
        p.resume()
        pingTimer = p
    }

    private func ping() {
        guard let conn = connection else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // Anything unanswered for a full second counts as a lost sample.
        if now - lastReply > 1_000_000_000 {
            lastReply = now
            publish(-1)
        }
        var d = Data(capacity: 12)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt16(0x5049)); put(pingSeq); put(now)
        pingSeq &+= 1
        conn.send(content: d, completion: .idempotent)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, self.connection === conn else { return }
            if let data, data.count == 12 {
                let sent = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= UInt64(littleEndian: sent) {
                    self.lastReply = now
                    self.publish(Double(now - UInt64(littleEndian: sent)) / 1_000_000)
                }
            }
            if error == nil { self.receive(conn) }
        }
    }

    private func publish(_ ms: Double) {
        DispatchQueue.main.async {
            self.rtt = ms >= 0 ? ms : nil
            self.history.append(ms)
            if self.history.count > Self.historyLength { self.history.removeFirst() }
        }
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
        receive(conn)
    }

    func stop() {
        timer?.cancel(); timer = nil
        pingTimer?.cancel(); pingTimer = nil
        connection?.cancel(); connection = nil
        running = false
        rtt = nil; history = []
        stopKeepAlive()
    }

    private func send() {
        queue.async { [self] in
            guard let conn = connection, !pads.isEmpty else { return }
            let data = Self.encode(pads, seq: seq, swapAB: layout.0, swapXY: layout.1)
            seq &+= 1
            conn.send(content: data, completion: .idempotent)
            DispatchQueue.main.async { self.packetsSent += 1 }
        }
    }

    static func encode(_ pads: [GCExtendedGamepad], seq: UInt16, swapAB: Bool, swapXY: Bool) -> Data {
        var b: UInt16 = 0
        func set(_ on: Bool, _ mask: UInt16) { if on { b |= mask } }
        var lt: Float = 0, rt: Float = 0
        var ls: (Float, Float) = (0, 0), rs: (Float, Float) = (0, 0)
        func larger(_ a: (Float, Float), _ x: Float, _ y: Float) -> (Float, Float) {
            x * x + y * y > a.0 * a.0 + a.1 * a.1 ? (x, y) : a
        }
        for p in pads {
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
            lt = max(lt, p.leftTrigger.value); rt = max(rt, p.rightTrigger.value)
            ls = larger(ls, p.leftThumbstick.xAxis.value, p.leftThumbstick.yAxis.value)
            rs = larger(rs, p.rightThumbstick.xAxis.value, p.rightThumbstick.yAxis.value)
        }

        func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        func trig(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }

        var d = Data(capacity: 16)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt16(0x504C)); put(seq); put(b)
        put(trig(lt)); put(trig(rt))
        put(axis(ls.0)); put(axis(ls.1))
        put(axis(rs.0)); put(axis(rs.1))
        return d
    }
}
