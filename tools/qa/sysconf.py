"""Minimal Wii SYSCONF reader/writer. usage: sysconf.py FILE [NAME=hexbytes ...]"""
import struct, sys
path = sys.argv[1]; d = bytearray(open(path, 'rb').read())
n = struct.unpack('>H', d[4:6])[0]
offs = [struct.unpack('>H', d[6 + i*2:8 + i*2])[0] for i in range(n)]
items = {}
for o in offs:
    t = d[o] >> 5; nl = (d[o] & 0x1F) + 1; name = d[o+1:o+1+nl].decode(); p = o + 1 + nl
    if t == 1: L = (struct.unpack('>H', d[p:p+2])[0] & 0x1FFF) + 1; p += 2
    elif t == 2: L = d[p] + 1; p += 1
    else: L = {3: 1, 4: 2, 5: 4, 6: 8, 7: 1}[t]
    items[name] = (t, p, L)
for a in sys.argv[2:]:
    k, v = a.split('='); t, p, L = items[k]; b = bytes.fromhex(v)
    d[p:p+len(b)] = b
if len(sys.argv) > 2: open(path, 'wb').write(d)
for k in ['IPL.IDL', 'IPL.LNG', 'IPL.SADR', 'IPL.AR', 'IPL.CB', 'IPL.CD', 'IPL.PC', 'IPL.E60', 'IPL.PGS']:
    if k in items: t, p, L = items[k]; print(k, 'type', t, 'len', L, d[p:p+min(L, 8)].hex())
