import struct, sys, re, hashlib, subprocess
from pathlib import Path
wad, iosc, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
src = open(iosc).read()
m = re.search(r'HANDLE_COMMON_KEY\] = \{TYPE_SECRET_KEY,\s*ObjectSubType::AES128,\s*\{\{([^}]*)\}\}', src)
ck = bytes(int(x,16) for x in re.findall(r'0x([0-9a-fA-F]{2})', m.group(1)))
b = open(wad,'rb').read()
h = struct.unpack('>IHHIIIIII', b[:32]); al=lambda n:(n+63)&~63
o = 0x40 + al(h[3]); tik = b[o:o+h[5]]; o += al(h[5]); tmd = b[o:o+h[6]]; o += al(h[6])
def aes(key, iv, data):
    return subprocess.run(['openssl','enc','-d','-aes-128-cbc','-nopad','-K',key.hex(),'-iv',iv.hex()],input=data,capture_output=True,check=True).stdout
tkey = aes(ck, tik[0x1DC:0x1E4]+b'\0'*8, tik[0x1BF:0x1CF])
out.mkdir(parents=True, exist_ok=True)
n = struct.unpack('>H', tmd[0x1DE:0x1E0])[0]
for i in range(n):
    cid, idx, ctype, size = struct.unpack('>IHHQ', tmd[0x1E4+36*i:0x1E4+36*i+16]); sha = tmd[0x1E4+36*i+16:0x1E4+36*i+36]
    enc = b[o:o+((size+15)&~15)]; o += al((size+15)&~15)
    dec = aes(tkey, struct.pack('>H', idx)+b'\0'*14, enc)[:size]
    ok = hashlib.sha1(dec).digest()==sha
    (out/f'{idx:02d}_{cid:08x}.app').write_bytes(dec)
    print(f'{idx:2d} {cid:08x} type={ctype:04x} size={size:9d} sha1_ok={ok} magic={dec[:8].hex()}')
