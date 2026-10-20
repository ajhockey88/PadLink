# PadLink wire protocol (UDP, port 26760, little-endian, 16 bytes)

| off | type | field                                  |
|-----|------|----------------------------------------|
| 0   | u16  | magic `0x504C` ("PL")                  |
| 2   | u16  | sequence (wraps; receiver drops stale) |
| 4   | u16  | XUSB button bitmask                    |
| 6   | u8   | left trigger 0-255                     |
| 7   | u8   | right trigger 0-255                    |
| 8   | i16  | left stick X  (-32768..32767)          |
| 10  | i16  | left stick Y                           |
| 12  | i16  | right stick X                          |
| 14  | i16  | right stick Y                          |

Buttons: DPAD_UP 0x1, DOWN 0x2, LEFT 0x4, RIGHT 0x8, START 0x10, BACK 0x20,
L3 0x40, R3 0x80, LB 0x100, RB 0x200, GUIDE 0x400, A 0x1000, B 0x2000, X 0x4000, Y 0x8000.

## Ping (latency test, 12 bytes)
| off | type | field                              |
|-----|------|------------------------------------|
| 0   | u16  | magic `0x5049` ("PI")              |
| 2   | u16  | sequence                           |
| 4   | u64  | sender timestamp (opaque to PC)    |

The receiver echoes the 12 bytes back unchanged; the app measures round-trip time.

## Rumble (PC -> phone, 4 bytes)
| off | type | field                                  |
|-----|------|----------------------------------------|
| 0   | u16  | magic `0x5052` ("PR")                  |
| 2   | u8   | large (left/low-frequency) motor 0-255 |
| 3   | u8   | small (right/high-frequency) motor 0-255 |

Sent to the phone's source address whenever the game changes vibration, and resent
every 100 ms while non-zero. The app stops vibrating if nothing arrives for 600 ms.

## Discovery
The receiver advertises a Bonjour/mDNS service `_padlink._udp` on port 26760
(instance name = PC host name). The app browses for it and connects to the service
endpoint, so no IP address is needed. Manual IP entry remains as a fallback.

## Pairing (optional signing)
When a pairing code is set, the phone appends an 8-byte tag to every control packet (24 bytes) and ping (20 bytes):
`tag = HMAC-SHA256(key, payload)[:8]` where `key = SHA256("padlink-v1:" + CODE)` and `CODE` is the 12 characters of the
pairing code (A-Z without I, L, O and 2-9, dashes ignored). The PC signs rumble packets (12 bytes) the same way when the phone
signs. With **Require pairing code** on, the PC drops unsigned or wrongly signed packets and replies (at most once a second)
with a 3-byte notice: u16 magic `0x5041` ("PA"), u8 `1` = pairing code needed. Unsigned packets keep their original lengths,
so old and new versions interoperate when pairing is off. This is authentication, not encryption: replays are limited only by the
sequence number.
