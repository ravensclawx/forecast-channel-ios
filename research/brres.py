import struct
def load(p): return open(p,'rb').read()
def group(d,off):
    size,n=struct.unpack('>II',d[off:off+8]); out=[]
    for i in range(1,n+1):
        e=off+8+i*16; no,do=struct.unpack('>ii',d[e+8:e+16])
        out.append((d[off+no:d.index(b'\0',off+no)].decode(),off+do))
    return out
def folders(d):
    return {f:group(d,o) for f,o in group(d,0x18)}
