package com.padlink.receiver

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // Produced by the Windows receiver's own functions (Windows/padlink_receiver.py).
    private val packet = hex("4c50070000100a14640038ff2c0170fe")
    private val tag = hex("5fff7c78d2ca0aad")
    private val key = Protocol.keyFor("ABCD-EFGH-JKMN")!!

    @Test
    fun tagMatchesTheWindowsReceiver() {
        assertArrayEquals(tag, Protocol.tagFor(key, packet, packet.size))
    }

    @Test
    fun signedPacketIsRecognised() {
        val signed = packet + tag
        val parsed = Protocol.parse(signed, signed.size, key)
        assertEquals(Protocol.Kind.INPUT, parsed.kind)
        assertTrue(parsed.signed)
    }

    @Test
    fun wrongTagOrNoKeyIsNotSigned() {
        val bad = packet + hex("0000000000000000")
        assertFalse(Protocol.parse(bad, bad.size, key).signed)
        val signed = packet + tag
        assertFalse(Protocol.parse(signed, signed.size, null).signed)
        assertFalse(Protocol.parse(packet, packet.size, key).signed)
    }

    @Test
    fun badLengthsAndMagicAreIgnored() {
        assertEquals(Protocol.Kind.NONE, Protocol.parse(packet, 15, null).kind)
        assertEquals(Protocol.Kind.NONE, Protocol.parse(hex("0000") + ByteArray(14), 16, null).kind)
        val ping = hex("49500100") + ByteArray(8)
        assertEquals(Protocol.Kind.PING, Protocol.parse(ping, ping.size, null).kind)
    }

    @Test
    fun shortCodeGivesNoKey() {
        assertNull(Protocol.keyFor(""))
        assertNull(Protocol.keyFor("ABCD"))
    }

    @Test
    fun sequenceWraps() {
        assertTrue(Protocol.newer(5, -1))
        assertTrue(Protocol.newer(6, 5))
        assertTrue(Protocol.newer(0, 0xFFFF))
        assertFalse(Protocol.newer(5, 5))
        assertFalse(Protocol.newer(4, 5))
    }

    @Test
    fun reportMapsButtonsAxesAndHat() {
        val packetValues = Protocol.i16(packet, 8) to Protocol.i16(packet, 10)
        assertEquals(100 to -200, packetValues)
        val out = ByteArray(Report.SIZE)
        // A, LB, d-pad up + right, LT 10, RT 20, left stick (100, -200), right stick (300, -400)
        Report.build(0x1000 or 0x100 or 0x1 or 0x8, 10, 20, 100, -200, 300, -400, out)
        assertEquals((1 shl 0) or (1 shl 6), Protocol.u16(out, 0))
        assertEquals(2, out[2].toInt()) // north-east
        assertEquals(100, Protocol.i16(out, 3))
        assertEquals(200, Protocol.i16(out, 5)) // Y flipped
        assertEquals(300, Protocol.i16(out, 7))
        assertEquals(400, Protocol.i16(out, 9))
        assertEquals(10, out[11].toInt())
        assertEquals(20, out[12].toInt())
    }

    @Test
    fun hatCoversAllDirections() {
        assertEquals(0, Report.hat(0))
        assertEquals(1, Report.hat(0x1))
        assertEquals(3, Report.hat(0x8))
        assertEquals(5, Report.hat(0x2))
        assertEquals(7, Report.hat(0x4))
        assertEquals(8, Report.hat(0x1 or 0x4))
        assertEquals(0, Report.hat(0x1 or 0x2)) // up+down cancel
    }

    @Test
    fun fullDeflectionDoesNotOverflow() {
        val out = ByteArray(Report.SIZE)
        Report.build(0, 255, 255, -32768, -32768, 32767, 32767, out)
        assertEquals(-32768, Protocol.i16(out, 3))
        assertEquals(32767, Protocol.i16(out, 5)) // -(-32768) clamped
        assertEquals(-32767, Protocol.i16(out, 9))
    }

    @Test
    fun descriptorMatchesReportSize() {
        // 15+1 button bits, 4+4 hat bits, 4 x 16-bit axes, 2 x 8-bit triggers
        assertEquals(13, (16 + 8 + 4 * 16 + 2 * 8) / 8)
        assertEquals(Report.SIZE, 13)
    }
}
