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
