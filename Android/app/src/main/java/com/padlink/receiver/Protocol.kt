package com.padlink.receiver

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** The PadLink wire format (see PROTOCOL.md) and the mapping to a USB HID gamepad report. */
object Protocol {
    const val PORT = 26760
    const val MAGIC = 0x504C
    const val PING_MAGIC = 0x5049
    const val PAIR_MAGIC = 0x5041
    const val INPUT_SIZE = 16
    const val PING_SIZE = 12
    const val TAG_LEN = 8
    private const val CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

    enum class Kind { NONE, PING, INPUT }

    class Parsed(val kind: Kind, val signed: Boolean)

    fun normalizeCode(text: String): String = text.uppercase().filter { it in CODE_ALPHABET }

    /** Null unless [code] holds a full 12-character pairing code. */
    fun keyFor(code: String): ByteArray? {
        val c = normalizeCode(code)
        if (c.length != 12) return null
        return MessageDigest.getInstance("SHA-256").digest("padlink-v1:$c".toByteArray())
    }

    fun tagFor(key: ByteArray, data: ByteArray, len: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update(data, 0, len)
        return mac.doFinal().copyOf(TAG_LEN)
    }

    fun u16(b: ByteArray, off: Int): Int = (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)
    fun i16(b: ByteArray, off: Int): Int = u16(b, off).toShort().toInt()

    fun parse(buf: ByteArray, len: Int, key: ByteArray?): Parsed {
        if (len < 2) return Parsed(Kind.NONE, false)
        val magic = u16(buf, 0)
        val kind: Kind
        val payload: Int
        if (magic == PING_MAGIC && (len == PING_SIZE || len == PING_SIZE + TAG_LEN)) {
            kind = Kind.PING; payload = PING_SIZE
        } else if (magic == MAGIC && (len == INPUT_SIZE || len == INPUT_SIZE + TAG_LEN)) {
            kind = Kind.INPUT; payload = INPUT_SIZE
        } else {
            return Parsed(Kind.NONE, false)
        }
        val signed = key != null && len == payload + TAG_LEN &&
            MessageDigest.isEqual(buf.copyOfRange(payload, len), tagFor(key, buf, payload))
        return Parsed(kind, signed)
    }

    /** True when [seq] is ahead of [last] (16-bit wrap); [last] < 0 means nothing received yet. */
    fun newer(seq: Int, last: Int): Boolean = last < 0 || ((seq - last) and 0xFFFF) in 1..0x7FFF
}

/**
 * HID report for the virtual pad. It identifies as an Xbox 360 controller (045E:028E), so Android applies its
 * built-in Xbox layout: left stick X/Y, right stick Rx/Ry, triggers Z/Rz, hat for the d-pad.
 *
 * Layout (13 bytes): 15 button bits + 1 pad bit, hat (4 bits) + 4 pad bits, X, Y, Rx, Ry as i16, Z, Rz as u8.
 */
object Report {
    const val SIZE = 13

    val DESCRIPTOR = byteArrayOf(
        0x05, 0x01, 0x09, 0x05, 0xA1.toByte(), 0x01,                       // Gamepad, Application collection
        0x05, 0x09, 0x19, 0x01, 0x29, 0x0F, 0x15, 0x00, 0x25, 0x01,        // 15 buttons
        0x75, 0x01, 0x95.toByte(), 0x0F, 0x81.toByte(), 0x02,
        0x75, 0x01, 0x95.toByte(), 0x01, 0x81.toByte(), 0x03,              // 1 bit padding
        0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08,                    // hat 1..8, 0 = released
        0x75, 0x04, 0x95.toByte(), 0x01, 0x81.toByte(), 0x42,
        0x75, 0x04, 0x95.toByte(), 0x01, 0x81.toByte(), 0x03,              // 4 bits padding
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34,        // X, Y, Rx, Ry
        0x16, 0x00, 0x80.toByte(), 0x26, 0xFF.toByte(), 0x7F,
        0x75, 0x10, 0x95.toByte(), 0x04, 0x81.toByte(), 0x02,
        0x05, 0x01, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00,                    // Z, Rz (triggers)
        0x26, 0xFF.toByte(), 0x00, 0x75, 0x08, 0x95.toByte(), 0x02, 0x81.toByte(), 0x02,
        0xC0.toByte(),
    )

    // XUSB mask -> bit index in the button field; the order matches Android's Xbox 360 key layout.
    private val BUTTONS = arrayOf(
        0x1000 to 0, 0x2000 to 1, 0x4000 to 3, 0x8000 to 4,      // A B X Y
        0x0100 to 6, 0x0200 to 7,                                 // LB RB
        0x0020 to 10, 0x0010 to 11, 0x0400 to 12,                 // Back Start Guide
        0x0040 to 13, 0x0080 to 14,                               // L3 R3
    )

    fun hat(dpad: Int): Int {
        val up = dpad and 0x1 != 0
        val down = dpad and 0x2 != 0
        val left = dpad and 0x4 != 0
        val right = dpad and 0x8 != 0
        return when {
            up && !down && right && !left -> 2
            up && !down && left && !right -> 8
            down && !up && right && !left -> 4
            down && !up && left && !right -> 6
            up && !down -> 1
            down && !up -> 5
            right && !left -> 3
            left && !right -> 7
            else -> 0
        }
    }

    private fun put16(out: ByteArray, off: Int, v: Int) {
        out[off] = v.toByte()
        out[off + 1] = (v shr 8).toByte()
    }

    /** HID Y grows downward, XUSB Y grows upward. */
    private fun flip(y: Int): Int = if (y <= -32768) 32767 else -y

    fun build(buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int, out: ByteArray) {
        var bits = 0
        for ((mask, bit) in BUTTONS) if (buttons and mask != 0) bits = bits or (1 shl bit)
        put16(out, 0, bits)
        out[2] = hat(buttons and 0xF).toByte()
        put16(out, 3, lx)
        put16(out, 5, flip(ly))
        put16(out, 7, rx)
        put16(out, 9, flip(ry))
        out[11] = lt.toByte()
        out[12] = rt.toByte()
    }
}
