"""Sparse image whose ack sector (LBA 0x11) answers like a G-RAID controller.
A file cannot vary its reply per command, so every query returns the same bytes;
this exercises the read loop, signature check and capabilities parsing end to end."""
import struct, sys
s = bytearray(512)
s[0:16] = b"__ASMEDIA2109A__"
s[0x1F0:0x200] = b"_PORTMULTIPLIER_"
s[0x30] = 0x20
caps = bytearray(0x48)
caps[0] = 0x21
caps[8:16] = bytes([0, 0, 0x16, 0x05, 0x24, 0x00, 0x01, 0x02])
caps[36] = 2
caps[49:55] = b"G-RAID"
caps[64:72] = bytes([1, 2, 3, 4, 5, 6, 7, 8])
s[0x50:0x50 + 0x48] = caps
with open(sys.argv[1], "wb") as f:
    f.truncate((0x5FFF + 1) * 512)
    f.seek(0x11 * 512)
    f.write(s)
