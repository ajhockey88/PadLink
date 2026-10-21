import AVFoundation
import CryptoKit
import CoreHaptics
import Foundation
import GameController
import Network
import UIKit

struct DiscoveredPC: Identifiable, Hashable {
    let id: String
    let endpoint: NWEndpoint
}

enum LinkState {
    case stopped, searching, connecting, connected, reconnecting, needsPairing

    var text: String {
        switch self {
        case .stopped: return "Stopped"
        case .searching: return "Searching for PC…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .needsPairing: return "Pairing code needed"
        }
    }
}

/// One vibration motor on a controller, driven by a looping haptic player whose intensity we update live.
private final class Motor {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var on = false

    init?(controller: GCController, locality: GCHapticsLocality) {
        guard let haptics = controller.haptics,
              haptics.supportedLocalities.contains(locality),
              let e = haptics.createEngine(withLocality: locality) else { return nil }
        e.isAutoShutdownEnabled = false
        e.stoppedHandler = { [weak self] _ in self?.on = false; self?.player = nil }
        e.resetHandler = { [weak self] in
            self?.on = false; self?.player = nil
            try? self?.engine?.start()
        }
        do { try e.start() } catch { return nil }
        engine = e
    }

    func set(_ value: Float) {
        do {
            if value <= 0 {
                if on { try player?.stop(atTime: CHHapticTimeImmediate); on = false }
                return
            }
            if player == nil { player = try makePlayer() }
            if !on { try player?.start(atTime: CHHapticTimeImmediate); on = true }
            let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: min(value, 1), relativeTime: 0)
            try player?.sendParameters([p], atTime: CHHapticTimeImmediate)
        } catch {
            on = false; player = nil
        }
    }

    func stop() {
        set(0)
        engine?.stop()
    }

    private func makePlayer() throws -> CHHapticAdvancedPatternPlayer {
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
            relativeTime: 0, duration: 30)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let p = try engine!.makeAdvancedPlayer(with: pattern)
        p.loopEnabled = true
        return p
    }
}

struct Tuning {
    var swapAB: Bool
    var swapXY: Bool
    var stick: Float    // radial dead zone, 0...0.3
    var trigger: Float  // trigger dead zone, 0...0.3
}

/// Reads wired controllers via GameController, streams them to the PC over UDP, and relays rumble back.
final class PadLink: ObservableObject {
    static let port: NWEndpoint.Port = 26760
    static let serviceType = "_padlink._udp"
    static let historyLength = 120
    private static let second: UInt64 = 1_000_000_000

    @Published var controllerName: String?
    @Published var running = false
    @Published var packetsSent = 0
    /// How often the controller's current state is re-sent even if nothing changed (changes always go out at once).
    @Published var sendRate = (UserDefaults.standard.object(forKey: "sendHz") as? Int) ?? 250 {
        didSet {
            UserDefaults.standard.set(sendRate, forKey: "sendHz")
            let interval = 1.0 / Double(max(sendRate, 1))
            queue.async { self.timer?.schedule(deadline: .now(), repeating: interval) }
        }
    }
    @Published var state: LinkState = .stopped
    @Published var pcs: [DiscoveredPC] = []
    @Published var selectedPC: String? = UserDefaults.standard.string(forKey: "pcName")
    @Published var connectedPC: String?

    // Latency test (round trip to the PC receiver), measured ~5x per second while testing.
    @Published var testing = false
    @Published var benchmark: BenchmarkState = .idle
    @Published var savedControllers: [SavedController] = PadLink.loadSaved()
    @Published var previousRun: BenchmarkRun?  // last run on the same controller, for comparison
    /// Experimental, off by default: read each input report's own iOS timestamp during a benchmark (iOS 17).
    @Published var preciseTimestamps = UserDefaults.standard.bool(forKey: "preciseTS") {
        didSet { UserDefaults.standard.set(preciseTimestamps, forKey: "preciseTS") }
    }
    /// Set at launch if the previous benchmark never finished, so a crash is noticed and reported.
    @Published var crashNote: String?
    @Published var rtt: Double?               // latest, milliseconds
    @Published var history: [Double] = []     // recent samples, -1 = lost

    @Published var auto = (UserDefaults.standard.object(forKey: "auto") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(auto, forKey: "auto")
            if running { queue.async { self.reconnect() } }
        }
    }
    @Published var manualHost = UserDefaults.standard.string(forKey: "host") ?? "" {
        didSet {
            UserDefaults.standard.set(manualHost, forKey: "host")
            if running && !auto { queue.async { self.reconnect() } }
        }
    }

    // Swap face buttons and stick/trigger tuning. Read on the network queue, written from the UI.
    @Published var swapAB = UserDefaults.standard.bool(forKey: "swapAB") {
        didSet { UserDefaults.standard.set(swapAB, forKey: "swapAB"); refreshTuning() }
    }
    @Published var swapXY = UserDefaults.standard.bool(forKey: "swapXY") {
        didSet { UserDefaults.standard.set(swapXY, forKey: "swapXY"); refreshTuning() }
    }
    @Published var stickDeadZone = UserDefaults.standard.double(forKey: "stickDZ") {
        didSet { UserDefaults.standard.set(stickDeadZone, forKey: "stickDZ"); refreshTuning() }
    }
    @Published var triggerDeadZone = UserDefaults.standard.double(forKey: "trigDZ") {
        didSet { UserDefaults.standard.set(triggerDeadZone, forKey: "trigDZ"); refreshTuning() }
    }
    private var tuning = Tuning(swapAB: UserDefaults.standard.bool(forKey: "swapAB"),
                                swapXY: UserDefaults.standard.bool(forKey: "swapXY"),
                                stick: Float(UserDefaults.standard.double(forKey: "stickDZ")),
                                trigger: Float(UserDefaults.standard.double(forKey: "trigDZ")))

    private func refreshTuning() {
        tuning = Tuning(swapAB: swapAB, swapXY: swapXY, stick: Float(stickDeadZone), trigger: Float(triggerDeadZone))
    }

    func resetTuning() {
        stickDeadZone = 0
        triggerDeadZone = 0
    }

    // Pairing: the code typed in the app derives a key; every packet is signed with it when set.
    @Published var pairingCode = UserDefaults.standard.string(forKey: "pairingCode") ?? "" {
        didSet {
            UserDefaults.standard.set(pairingCode, forKey: "pairingCode")
            let key = Self.makeKey(pairingCode)
            queue.async { self.key = key; self.lastPairingNeeded = 0 }
        }
    }
    private var key: SymmetricKey? = PadLink.makeKey(UserDefaults.standard.string(forKey: "pairingCode") ?? "")
    private var lastPairingNeeded: UInt64 = 0

    static let codeAlphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// 12 valid characters (dashes and spaces ignored) become the signing key; fewer means "no code".
    static func makeKey(_ code: String) -> SymmetricKey? {
        let clean = code.uppercased().filter { codeAlphabet.contains($0) }
        guard clean.count == 12 else { return nil }
        let digest = SHA256.hash(data: Data(("padlink-v1:" + clean).utf8))
        return SymmetricKey(data: Data(digest))
    }

    private static func tag(_ payload: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: key).prefix(8))
    }

    private func signed(_ payload: Data) -> Data {
        guard let key else { return payload }
        return payload + Self.tag(payload, key: key)
    }

    /// True if the datagram has the length for its type and (when we have a code) a valid tag.
    private func authentic(_ data: Data, payload: Int) -> Bool {
        guard let key else { return data.count == payload }
        guard data.count == payload + 8 else { return false }
        return Self.tag(data.prefix(payload), key: key) == data.suffix(8)
    }

    // Network state: only touched on `queue`.
    private let queue = DispatchQueue(label: "padlink.net", qos: .userInteractive)
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var currentTarget: String?
    private var timer: DispatchSourceTimer?
    private var sentCount = 0  // queue; copied to packetsSent a few times a second, not per packet
    private var tickTimer: DispatchSourceTimer?
    private var seq: UInt16 = 0
    private var pingSeq: UInt16 = 0
    private var tickCount = 0
    private var pads: [GCExtendedGamepad] = []
    private var lastReply: UInt64 = 0        // last time the PC answered (any ping), 0 = never
    private var lastSampleReply: UInt64 = 0  // for lost-sample accounting in the latency test
    private var lastReconnect: UInt64 = 0
    private var searchStarted: UInt64 = 0
    private var testingQ = false
    private var benchTimer: DispatchSourceTimer?
    private var benchRunning = false
    private var benchCapturing = false                // main thread: recording controller events
    private var benchEvents: [(UInt64, String)] = []   // main thread: (uptime ns, controller name)
    private let benchInputQueue = DispatchQueue(label: "padlink.bench.input", qos: .userInteractive)
    private let benchLock = NSLock()
    private var queueStamps: [String: [UInt64]] = [:]  // guarded by benchLock: event time per input report
    private var queuesActive = false                   // main thread: the input queue is switched on

    /// Breadcrumb for crash diagnosis: the step a benchmark is in. "done" means it finished normally.
    private func stage(_ name: String) {
        UserDefaults.standard.set(name, forKey: "benchStage")
        UserDefaults.standard.synchronize()  // flush now: a crash right after must not lose it
    }
    private var benchTicks = 0
    private var benchSent = 0
    private var benchSeqs = Set<UInt16>()
    private var benchRTTs: [Double] = []
    private static let benchPings = 200       // one every 50 ms, about 10 seconds
    private static let benchGraceTicks = 12   // wait 0.6 s for the last replies

    // Controller + rumble state: main thread.
    private var attached: [GCController] = []
    private var lastActive: GCController?
    private var motorOwner: GCController?
    private var motorL: Motor?
    private var motorR: Motor?
    private var rumbleStamp: UInt64 = 0
    private var rumbleOn = false
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
        if let last = UserDefaults.standard.string(forKey: "benchStage"), last != "done" {
            crashNote = "The last benchmark ended unexpectedly (during: \(last)). Precise timestamps were turned off. Please report this step name."
            preciseTimestamps = false
            UserDefaults.standard.set(false, forKey: "preciseTS")
            UserDefaults.standard.set("done", forKey: "benchStage")
        }
    }

    // MARK: Controllers

    /// Every connected controller feeds the same virtual pad; their inputs are merged.
    private func attach(_ c: GCController) {
        guard let gp = c.extendedGamepad else { return }
        if !attached.contains(where: { $0 === c }) { attached.append(c) }
        gp.valueChangedHandler = { [weak self] g, _ in
            self?.lastActive = g.controller
            self?.noteEvent(g.controller)
            self?.send()
        }
        syncPads()
    }

    private func detach(_ c: GCController) {
        attached.removeAll { $0 === c }
        c.extendedGamepad?.valueChangedHandler = nil
        if lastActive === c { lastActive = nil }
        if motorOwner === c { stopRumble(); motorOwner = nil; motorL = nil; motorR = nil }
        syncPads()
    }

    private func syncPads() {
        let gps = attached.compactMap { $0.extendedGamepad }
        queue.async { self.pads = gps }
        let n = attached.count
        controllerName = n == 0 ? nil : (attached[0].vendorName ?? "Controller") + (n > 1 ? " (+\(n - 1) more)" : "")
    }

    // MARK: Background keep-alive

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

    // MARK: Start / stop

    func start() {
        guard !running else { return }
        running = true
        state = .searching
        startKeepAlive()
        queue.async { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            lastReply = 0; lastReconnect = now; searchStarted = now
            openLink()

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(max(sendRate, 1)))
            t.setEventHandler { [weak self] in self?.sendNow() }
            t.resume()
            timer = t

            let k = DispatchSource.makeTimerSource(queue: queue)
            k.schedule(deadline: .now() + 0.2, repeating: 0.2)
            k.setEventHandler { [weak self] in self?.tick() }
            k.resume()
            tickTimer = k
        }
    }

    func stop() {
        stopTest()
        cancelBenchmark()
        running = false
        state = .stopped
        connectedPC = nil
        stopRumble()
        queue.async { [self] in
            timer?.cancel(); timer = nil
            tickTimer?.cancel(); tickTimer = nil
            browser?.cancel(); browser = nil
            connection?.cancel(); connection = nil
            currentTarget = nil
        }
        stopKeepAlive()
    }

    func select(_ pc: DiscoveredPC) {
        UserDefaults.standard.set(pc.id, forKey: "pcName")
        selectedPC = pc.id
        queue.async { self.connect(to: pc.endpoint, name: pc.id) }
    }

    // MARK: Latency test

    /// The test pings 5x/s and records samples; normal use only sends a 1 Hz status ping.
    func startTest() {
        guard running, !testing else { return }
        history = []; rtt = nil
        testing = true
        queue.async { self.testingQ = true; self.lastSampleReply = DispatchTime.now().uptimeNanoseconds }
    }

    func stopTest() {
        testing = false
        rtt = nil; history = []
        queue.async { self.testingQ = false }
    }

    // MARK: Benchmark

    private static func loadSaved() -> [SavedController] {
        guard let data = UserDefaults.standard.data(forKey: "savedControllers") else { return [] }
        return (try? JSONDecoder().decode([SavedController].self, from: data)) ?? []
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(savedControllers) {
            UserDefaults.standard.set(data, forKey: "savedControllers")
        }
    }

    /// Fastest controller first.
    var sortedControllers: [SavedController] {
        savedControllers.sorted { ($0.latest?.total ?? .infinity) < ($1.latest?.total ?? .infinity) }
    }

    func removeController(_ name: String) {
        savedControllers.removeAll { $0.name == name }
        persistSaved()
    }

    func clearSaved() {
        savedControllers = []
        persistSaved()
    }

    private func controllerName(_ c: GCController?) -> String? {
        guard let c else { return nil }
        let base = c.vendorName ?? "Controller"
        return c.productCategory.isEmpty ? base : "\(base) (\(c.productCategory))"
    }

    private func noteEvent(_ c: GCController?) {
        guard benchCapturing, let name = controllerName(c) else { return }
        benchEvents.append((DispatchTime.now().uptimeNanoseconds, name))
    }

    private func save(_ run: BenchmarkRun, as name: String) {
        previousRun = savedControllers.first { $0.name == name }?.latest
        if let i = savedControllers.firstIndex(where: { $0.name == name }) {
            savedControllers[i].runs.append(run)
            if savedControllers[i].runs.count > 10 { savedControllers[i].runs.removeFirst() }
        } else {
            savedControllers.append(SavedController(name: name, runs: [run]))
        }
        persistSaved()
    }

    /// During a benchmark only: ask iOS for every input report with its own timestamp (iOS 17 input state queue),
    /// which is more precise than counting callbacks. Normal play never uses this, so it cannot affect it.
    private func enableInputQueues() {
        benchLock.lock(); queueStamps = [:]; benchLock.unlock()
        guard preciseTimestamps, #available(iOS 17.0, *) else { return }  // needs iOS 17; every USB-C iPhone has it
        queuesActive = true
        for c in attached {
            guard let name = controllerName(c) else { continue }
            let input = c.input
            input.inputStateQueueDepth = 128
            input.queue = benchInputQueue
            input.inputStateAvailableHandler = { [weak self] input in
                var stamps: [UInt64] = []
                while let state = input.nextInputState() {
                    let seconds = state.lastEventTimestamp
                    if seconds.isFinite, seconds > 0, seconds < 1e9 { stamps.append(UInt64(seconds * 1_000_000_000)) }
                }
                guard let self, !stamps.isEmpty else { return }
                self.benchLock.lock()
                self.queueStamps[name, default: []].append(contentsOf: stamps)
                self.benchLock.unlock()
            }
        }
    }

    private func disableInputQueues() {
        guard queuesActive, #available(iOS 17.0, *) else { return }
        queuesActive = false
        let inputs = attached.map { $0.input }
        for input in inputs { input.inputStateAvailableHandler = nil }  // stop callbacks first
        stage("finish:queue-depth")
        // Switch the queue off on its own queue after pending callbacks have had time to finish,
        // not on the main thread while one may still be draining.
        benchInputQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.stage("finish:queue-depth")
            for input in inputs { input.inputStateQueueDepth = 0 }
            self?.stage("done")
        }
    }

    /// 10 seconds: 200 signed pings (network) while you move a stick (controller report rate).
    func startBenchmark() {
        guard running, state == .connected, !benchmark.isRunning else {
            if !benchmark.isRunning { benchmark = .failed("Connect to a PC first, then run the benchmark.") }
            return
        }
        stage("start")
        crashNote = nil
        benchEvents = []
        benchCapturing = true
        previousRun = nil
        benchmark = .running(0)
        enableInputQueues()
        stage("running")
        queue.async { [self] in
            benchRTTs = []; benchSeqs = []; benchSent = 0; benchTicks = 0; benchRunning = true
            benchTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2, repeating: 0.05)
            t.setEventHandler { [weak self] in self?.benchTick() }
            t.resume()
            benchTimer = t
        }
    }

    func cancelBenchmark() {
        benchCapturing = false
        disableInputQueues()
        if benchmark.isRunning { benchmark = .idle }
        if !queuesActive { stage("done") }
        queue.async { [self] in
            benchRunning = false
            benchTimer?.cancel(); benchTimer = nil
        }
    }

    private func benchTick() {
        guard benchRunning else { return }
        benchTicks += 1
        if benchTicks <= Self.benchPings, let seq = sendPing(DispatchTime.now().uptimeNanoseconds) {
            benchSeqs.insert(seq)
            benchSent += 1
        }
        if benchTicks % 10 == 0 {
            let progress = min(1, Double(benchTicks) / Double(Self.benchPings + Self.benchGraceTicks))
            DispatchQueue.main.async { if self.benchmark.isRunning { self.benchmark = .running(progress) } }
        }
        guard benchTicks >= Self.benchPings + Self.benchGraceTicks else { return }

        benchRunning = false
        benchTimer?.cancel(); benchTimer = nil
        let sent = benchSent, rtts = benchRTTs
        DispatchQueue.main.async {
            self.benchCapturing = false
            self.stage("finish:stop")
            let hadQueues = self.queuesActive
            self.disableInputQueues()
            guard self.benchmark.isRunning else { if !hadQueues { self.stage("done") }; return }  // cancelled meanwhile
            if sent == 0 || rtts.isEmpty {
                self.benchmark = .failed(sent == 0 ? "Not connected to a PC." : "The PC did not answer any pings. Check the connection and the pairing code.")
                if !hadQueues { self.stage("done") }
                return
            }
            self.stage("finish:compute")
            // The controller you actually moved is the one with the most events.
            self.benchLock.lock()
            let stamped = self.queueStamps
            self.benchLock.unlock()
            let fromQueue = (hadQueues ? stamped : [:]).max(by: { $0.value.count < $1.value.count })
                .flatMap { ControllerStats.make(name: $0.key, times: $0.value.sorted(), source: "input timestamps") }
            // If iOS gave no usable timestamps, fall back to counting callbacks.
            let grouped = Dictionary(grouping: self.benchEvents, by: { $0.1 })
            let busiest = grouped.max(by: { $0.value.count < $1.value.count })
            let fromCallbacks = busiest.flatMap { ControllerStats.make(name: $0.key, times: $0.value.map { $0.0 }, source: "app callbacks, less precise") }
            let stats = fromQueue ?? fromCallbacks
            let run = BenchmarkRun(network: BenchmarkResult(rtts: rtts, sent: sent), controller: stats)
            self.stage("finish:save")
            if let stats { self.save(run, as: stats.name) }
            self.stage("finish:show")
            self.benchmark = .done(run)
            if !hadQueues { self.stage("done") }  // with the queue on, the delayed reset marks "done" itself
        }
    }

    // MARK: Connection management (queue)

    private func openLink() {
        if auto { startBrowsing() } else { connectManual() }
    }

    private func startBrowsing() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
        b.start(queue: queue)
        browser = b
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        let list = results.compactMap { r -> DiscoveredPC? in
            if case let .service(name, _, _, _) = r.endpoint { return DiscoveredPC(id: name, endpoint: r.endpoint) }
            return nil
        }.sorted { $0.id < $1.id }
        DispatchQueue.main.async { self.pcs = list }
        guard auto else { return }
        let saved = UserDefaults.standard.string(forKey: "pcName")
        let target = list.first { $0.id == saved } ?? (list.count == 1 ? list[0] : nil)
        if let target, currentTarget != target.id { connect(to: target.endpoint, name: target.id) }
    }

    private func connectManual() {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: Self.port), name: "ip:" + host)
    }

    private func connect(to endpoint: NWEndpoint, name: String) {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        let conn = NWConnection(to: endpoint, using: params)
        conn.start(queue: queue)
        connection?.cancel()
        connection = conn
        currentTarget = name
        lastReply = 0
        lastReconnect = DispatchTime.now().uptimeNanoseconds
        receive(conn)
        DispatchQueue.main.async { self.connectedPC = name.hasPrefix("ip:") ? String(name.dropFirst(3)) : name }
    }

    /// Throw the link away and build it again (PC moved, Wi-Fi roamed, receiver restarted...).
    private func reconnect() {
        connection?.cancel(); connection = nil
        currentTarget = nil
        lastReconnect = DispatchTime.now().uptimeNanoseconds
        searchStarted = lastReconnect
        openLink()
    }

    private func setState(_ s: LinkState) {
        DispatchQueue.main.async { if self.running && self.state != s { self.state = s } }
    }

    /// Every 0.2 s: status ping, lost-sample accounting, connection watchdog, rumble watchdog.
    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        tickCount += 1
        if testingQ || tickCount % 5 == 0 { sendPing(now) }

        if testingQ, now - lastSampleReply > Self.second {
            lastSampleReply = now
            publish(-1)
        }

        if lastReply != 0, now - lastReply < 3 * Self.second {
            setState(.connected)
        } else if lastPairingNeeded != 0, now - lastPairingNeeded < 3 * Self.second {
            setState(.needsPairing)
        } else if connection == nil {
            setState(.searching)
            // Old receiver without discovery, or no PC found: fall back to the typed IP.
            if auto, !manualHost.isEmpty, now - searchStarted > 4 * Self.second { connectManual() }
        } else if lastReply == 0, now - lastReconnect < 3 * Self.second {
            setState(.connecting)
        } else {
            setState(.reconnecting)
            if now - lastReconnect > 3 * Self.second { reconnect() }
        }

        let sentNow = sentCount
        DispatchQueue.main.async {
            if self.rumbleOn, now - self.rumbleStamp > 600_000_000 { self.stopRumble() }
            if self.packetsSent != sentNow { self.packetsSent = sentNow }
        }
    }

    // MARK: Packets (queue)

    @discardableResult
    private func sendPing(_ now: UInt64) -> UInt16? {
        guard let conn = connection else { return nil }
        let used = pingSeq
        var d = Data(capacity: 12)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt16(0x5049)); put(used); put(now)
        pingSeq &+= 1
        conn.send(content: signed(d), completion: .idempotent)
        return used
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, self.connection === conn else { return }
            if let data, data.count >= 2 {
                let magic = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)) }
                switch magic {
                case 0x5049 where self.authentic(data, payload: 12):  // ping echo
                    let sent = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
                    let now = DispatchTime.now().uptimeNanoseconds
                    let t0 = UInt64(littleEndian: sent)
                    if now >= t0 {
                        self.lastReply = now
                        self.lastPairingNeeded = 0
                        let echoSeq = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self)) }
                        if self.benchRunning, self.benchSeqs.remove(echoSeq) != nil {
                            self.benchRTTs.append(Double(now - t0) / 1_000_000)
                        }
                        if self.testingQ {
                            self.lastSampleReply = now
                            self.publish(Double(now - t0) / 1_000_000)
                        }
                    }
                case 0x5052 where self.authentic(data, payload: 4):  // rumble
                    let large = data[2], small = data[3]
                    DispatchQueue.main.async { self.applyRumble(large, small) }
                case 0x5041 where data.count == 3:  // the PC wants a (correct) pairing code
                    self.lastPairingNeeded = DispatchTime.now().uptimeNanoseconds
                default:
                    break
                }
            }
            if error == nil { self.receive(conn) }
        }
    }

    private func publish(_ ms: Double) {
        DispatchQueue.main.async {
            guard self.testing else { return }
            self.rtt = ms >= 0 ? ms : nil
            self.history.append(ms)
            if self.history.count > Self.historyLength { self.history.removeFirst() }
        }
    }

    private func send() {
        queue.async { self.sendNow() }
    }

    private func sendNow() {
        guard let conn = connection, !pads.isEmpty else { return }
        let data = signed(Self.encode(pads, seq: seq, tuning: tuning))
        seq &+= 1
        conn.send(content: data, completion: .idempotent)
        sentCount &+= 1
    }

    // MARK: Rumble (main)

    private func applyRumble(_ large: UInt8, _ small: UInt8) {
        rumbleStamp = DispatchTime.now().uptimeNanoseconds
        rumbleOn = large > 0 || small > 0
        guard let c = lastActive ?? attached.first else { return }
        if motorOwner !== c { buildMotors(for: c) }
        if let l = motorL, let r = motorR {
            l.set(Float(large) / 255); r.set(Float(small) / 255)
        } else if let m = motorL {
            m.set(Float(max(large, small)) / 255)
        }
    }

    private func buildMotors(for c: GCController) {
        motorL?.stop(); motorR?.stop()
        motorL = nil; motorR = nil
        motorOwner = c
        if let l = Motor(controller: c, locality: .leftHandle), let r = Motor(controller: c, locality: .rightHandle) {
            motorL = l; motorR = r
        } else {
            motorL = Motor(controller: c, locality: .default) ?? Motor(controller: c, locality: .all)
        }
    }

    private func stopRumble() {
        rumbleOn = false
        motorL?.set(0); motorR?.set(0)
    }

    // MARK: Encoding

    static func encode(_ pads: [GCExtendedGamepad], seq: UInt16, tuning: Tuning) -> Data {
        let swapAB = tuning.swapAB, swapXY = tuning.swapXY
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

        // Dead zones: ignore small movement, then rescale so full travel still reaches 100%.
        func shape(_ v: (Float, Float)) -> (Float, Float) {
            let dz = tuning.stick
            let m = (v.0 * v.0 + v.1 * v.1).squareRoot()
            guard dz > 0, m > 0 else { return v }
            guard m > dz else { return (0, 0) }
            let k = min(1, (m - dz) / (1 - dz)) / m
            return (v.0 * k, v.1 * k)
        }
        func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        func trig(_ v: Float) -> UInt8 {
            let dz = tuning.trigger
            let t = dz > 0 ? (v <= dz ? 0 : (v - dz) / (1 - dz)) : v
            return UInt8(max(0, min(1, t)) * 255)
        }
        ls = shape(ls); rs = shape(rs)

        var d = Data(capacity: 16)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt16(0x504C)); put(seq); put(b)
        put(trig(lt)); put(trig(rt))
        put(axis(ls.0)); put(axis(ls.1))
        put(axis(rs.0)); put(axis(rs.1))
        return d
    }
}
