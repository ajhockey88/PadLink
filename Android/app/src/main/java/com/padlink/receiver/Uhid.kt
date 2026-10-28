package com.padlink.receiver

import android.system.Os
import android.system.OsConstants
import java.io.FileDescriptor

/**
 * A virtual USB HID gamepad made through /dev/uhid. The shell user (which Shizuku runs us as) may open it, so no
 * root is needed, and every app then sees it as a normal controller.
 */
class Uhid private constructor(private val fd: FileDescriptor) : PadSink {
    private val event = ByteArray(EVENT_SIZE)
    private val neutral = ByteArray(Report.SIZE).also { Report.build(0, 0, 0, 0, 0, 0, 0, it) }
    @Volatile private var open = true

    init {
        create()
        Thread({ drain() }, "uhid-drain").apply { isDaemon = true }.start()
    }

    private fun put32(off: Int, v: Int) {
        event[off] = v.toByte(); event[off + 1] = (v shr 8).toByte()
        event[off + 2] = (v shr 16).toByte(); event[off + 3] = (v shr 24).toByte()
    }

    private fun create() {
        event.fill(0)
        put32(0, UHID_CREATE2)
        val name = "Microsoft X-Box 360 pad".toByteArray()
        System.arraycopy(name, 0, event, 4, name.size)
        val phys = "padlink".toByteArray()
        System.arraycopy(phys, 0, event, 132, phys.size)
        val rd = Report.DESCRIPTOR
        event[260] = rd.size.toByte(); event[261] = (rd.size shr 8).toByte()
        event[262] = 3; event[263] = 0                 // BUS_USB
        put32(264, 0x045E)                             // vendor: Microsoft
        put32(268, 0x028E)                             // product: Xbox 360 controller
        put32(272, 0x0114)                             // version
        put32(276, 0)                                  // country
        System.arraycopy(rd, 0, event, 280, rd.size)
        Os.write(fd, event, 0, event.size)
    }

    @Synchronized
    override fun update(report: ByteArray) {
        if (!open) return
        event.fill(0, 0, 8)
        put32(0, UHID_INPUT2)
        event[4] = report.size.toByte(); event[5] = 0
        System.arraycopy(report, 0, event, 6, report.size)
        try {
            Os.write(fd, event, 0, event.size)
        } catch (_: Exception) {
        }
    }

    override fun release() = update(neutral)

    // The kernel queues START/OPEN/OUTPUT events for us; read them so the queue never fills.
    private fun drain() {
        val buf = ByteArray(EVENT_SIZE)
        while (open) {
            try {
                if (Os.read(fd, buf, 0, buf.size) <= 0) break
            } catch (_: Exception) {
                break
            }
        }
    }

    @Synchronized
    fun close() {
        if (!open) return
        open = false
        try {
            event.fill(0, 0, 8)
            put32(0, UHID_DESTROY)
            Os.write(fd, event, 0, event.size)
        } catch (_: Exception) {
        }
        try {
            Os.close(fd)
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val UHID_DESTROY = 1
        private const val UHID_CREATE2 = 11
        private const val UHID_INPUT2 = 12
        private const val EVENT_SIZE = 4376 // sizeof(struct uhid_event)

        fun open(): Uhid {
            val fd = Os.open("/dev/uhid", OsConstants.O_RDWR, 0)
            return Uhid(fd)
        }
    }
}
