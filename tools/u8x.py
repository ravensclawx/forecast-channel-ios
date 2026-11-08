import struct, sys
from pathlib import Path
def lz77(d):
    if d[:4]==b'LZ77': d=d[4:]
    t=d[0]; size=d[1]|d[2]<<8|d[3]<<16; p=4
    if size==0: size=struct.unpack('<I',d[4:8])[0]; p=8
    o=bytearray()
    while len(o)<size:
        flags=d[p]; p+=1
        for bit in range(8):
            if len(o)>=size: break
            if flags & (0x80>>bit):
                if t==0x10:
                    b1,b2=d[p],d[p+1]; p+=2; n=(b1>>4)+3; disp=((b1&0xF)<<8|b2)+1
                else:
                    ind=d[p]>>4
                    if ind==0: n=((d[p]&0xF)<<4|d[p+1]>>4)+0x11; disp=((d[p+1]&0xF)<<8|d[p+2])+1; p+=3
                    elif ind==1: n=((d[p]&0xF)<<12|d[p+1]<<4|d[p+2]>>4)+0x111; disp=((d[p+2]&0xF)<<8|d[p+3])+1; p+=4
                    else: n=ind+1; disp=((d[p]&0xF)<<8|d[p+1])+1; p+=2
                for _ in range(n): o.append(o[-disp])
            else: o.append(d[p]); p+=1
    return bytes(o)
def maybe_dec(d):
    if d[:4]==b'LZ77' or (d[:1] in (b'\x10',b'\x11') and len(d)>8 and 0<(d[1]|d[2]<<8|d[3]<<16)<64<<20):
        try:
            r=lz77(d)
            return r
        except Exception: return d
    return d
def u8(d, out):
    root=struct.unpack('>I',d[4:8])[0]
    n=struct.unpack('>I',d[root+8:root+12])[0]; st=root+n*12
    def name(o): e=d.index(b'\0',st+o); return d[st+o:e].decode('latin1')
    stack=[(n,out)]; cur=out
    i=1
    def walk(i,end,path):
        while i<end:
            ty=d[root+i*12]; no=int.from_bytes(d[root+i*12+1:root+i*12+4],'big')
            a,b=struct.unpack('>II',d[root+i*12+4:root+i*12+12]); nm=name(no)
            if ty==1:
                p=path/nm; p.mkdir(parents=True,exist_ok=True); i=walk(i+1,b,p)
            else:
                handle(d[a:a+b], path/nm); i+=1
        return i
    out.mkdir(parents=True,exist_ok=True); walk(1,n,out)
def handle(d, path):
    d=maybe_dec(d)
    if d[:4]==b'\x55\xaa\x38\x2d': u8(d, path.with_name(path.name+'.d'))
    else: path.write_bytes(d)
for f in sys.argv[1:-1]:
    handle(Path(f).read_bytes(), Path(sys.argv[-1])/Path(f).name)
