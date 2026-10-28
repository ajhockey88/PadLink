package com.padlink.receiver

import kotlin.system.exitProcess

/**
 * Runs inside the Shizuku-started shell process. The UDP socket lives here too, so a packet goes from the network
 * straight to the virtual gamepad without crossing into the app process.
 */
class GamepadUserService : IGamepadService.Stub() {
    private var uhid: Uhid? = null
    private var receiver: Receiver? = null
    private var thread: Thread? = null
    private var startError: String? = null

    @Synchronized
    override fun destroy() {
        stop()
        exitProcess(0)
    }

    @Synchronized
    override fun start(port: Int, code: String): Boolean {
        stop()
        startError = null
        return try {
            val pad = Uhid.open()
            val r = Receiver(pad, Protocol.keyFor(code), port)
            uhid = pad
            receiver = r
            thread = Thread({ r.run() }, "padlink-udp").apply {
                priority = Thread.MAX_PRIORITY
                start()
            }
            true
        } catch (t: Throwable) {
            startError = "Could not create the virtual controller: ${t.message}"
            false
        }
    }

    @Synchronized
    override fun stop() {
        receiver?.stop()
        thread?.join(1000)
        uhid?.close()
        receiver = null
        thread = null
        uhid = null
    }

    @Synchronized
    override fun status(): String {
        val r = receiver ?: return "idle;0;;${startError ?: ""}"
        val state = when {
            r.error != null -> "idle"
            r.connected() -> "connected"
            r.listening -> "listening"
            else -> "idle"
        }
        return "$state;${r.packets};${r.phoneIp ?: ""};${r.error ?: ""}"
    }
}
