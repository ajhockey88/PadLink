package com.padlink.receiver

import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

interface PadSink {
    fun update(report: ByteArray)
    fun release()
}

/** Listens for PadLink packets and feeds the virtual pad. Mirrors the Windows receiver's loop. */
class Receiver(private val sink: PadSink, private val key: ByteArray?, private val port: Int) {
    @Volatile var running = true
    @Volatile var packets = 0L
    @Volatile var phoneIp: String? = null
    @Volatile var lastSeenMs = 0L
    @Volatile var error: String? = null
    @Volatile var listening = false

    private var socket: DatagramSocket? = null

    fun stop() {
        running = false
        socket?.close()
    }

    fun connected(): Boolean = System.currentTimeMillis() - lastSeenMs < 2000 && lastSeenMs != 0L

    fun run() {
        val s = try {
            DatagramSocket(null).apply {
                reuseAddress = true
                bind(InetSocketAddress(port))
                soTimeout = 250
                trafficClass = 0xB8 // expedited forwarding, where the network honours it
            }
        } catch (e: Exception) {
            error = "Port $port could not be opened: ${e.message}"
            return
        }
        socket = s
        listening = true
        val buf = ByteArray(64)
        val pkt = DatagramPacket(buf, buf.size)
        val report = ByteArray(Report.SIZE)
        var last = -1
        var idle = true
        var lastInput = 0L
        var lastNotice = 0L

        while (running) {
            try {
                pkt.length = buf.size
                s.receive(pkt)
                val len = pkt.length
                val parsed = Protocol.parse(buf, len, key)
                var kind = parsed.kind
                val now = System.currentTimeMillis()
                if (kind != Protocol.Kind.NONE && key != null && !parsed.signed) {
                    if (now - lastNotice > 1000) {
                        lastNotice = now
                        val notice = byteArrayOf(0x41, 0x50, 1)
                        s.send(DatagramPacket(notice, notice.size, pkt.socketAddress))
                    }
                    kind = Protocol.Kind.NONE
                }
                if (kind != Protocol.Kind.NONE) {
                    phoneIp = pkt.address.hostAddress
                    lastSeenMs = now
                }
                if (kind == Protocol.Kind.PING) {
                    s.send(DatagramPacket(buf, len, pkt.socketAddress))
                } else if (kind == Protocol.Kind.INPUT) {
                    val seq = Protocol.u16(buf, 2)
                    if (Protocol.newer(seq, last)) {
                        last = seq
                        lastInput = now
                        idle = false
                        packets++
                        Report.build(
                            Protocol.u16(buf, 4), buf[6].toInt() and 0xFF, buf[7].toInt() and 0xFF,
                            Protocol.i16(buf, 8), Protocol.i16(buf, 10), Protocol.i16(buf, 12), Protocol.i16(buf, 14),
                            report,
                        )
                        sink.update(report)
                    }
                }
            } catch (_: SocketTimeoutException) {
            } catch (e: IOException) {
                if (!running) break
            }
            if (!idle && System.currentTimeMillis() - lastInput > 1000) {
                sink.release() // phone went quiet: let go of every button and stick
                idle = true
                last = -1
            }
        }
        listening = false
        s.close()
        sink.release()
    }
}
