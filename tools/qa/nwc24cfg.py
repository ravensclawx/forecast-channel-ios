"""Mark the NWC24 config as registered (what the Wii Menu does when WiiConnect24 is first enabled). usage: nwc24cfg.py FILE"""
import struct, sys
p = sys.argv[1]; d = bytearray(open(p, 'rb').read())
struct.pack_into('>Q', d, 0x08, 0x0000_1234_5678_9ABC)   # nwc24 id (any non-zero)
struct.pack_into('>I', d, 0x10, 1)                        # id_generation
struct.pack_into('>I', d, 0x14, 2)                        # creation_stage = Registered
struct.pack_into('>I', d, 0x3F8, 1)                       # enable_booting
s = sum(struct.unpack('>255I', d[:0x3FC])) & 0xFFFFFFFF
struct.pack_into('>I', d, 0x3FC, s)
open(p, 'wb').write(d); print('nwc24msg.cfg registered, checksum %08x' % s)
