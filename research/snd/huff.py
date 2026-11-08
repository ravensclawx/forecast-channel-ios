import struct,sys
def huff(d):
    bits=d[0]&0xF; size=d[1]|d[2]<<8|d[3]<<16; p=4
    tsize=(d[p]+1)*2; root=p+1; p=p+tsize
    out=bytearray(); cur=0; nb=0; pos=root
    while len(out)<size:
        word=struct.unpack('<I',d[p:p+4])[0]; p+=4
        for i in range(32):
            bit=(word>>31)&1; word<<=1
            node=d[pos]; child=(pos&~1)+(node&0x3F)*2+2
            if bit==0: leaf=node&0x80; pos=child
            else: leaf=node&0x40; pos=child+1
            if leaf:
                cur|=d[pos]<<nb; nb+=bits; pos=root
                if nb==8:
                    out.append(cur); cur=0; nb=0
                    if len(out)>=size: break
    return bytes(out)
o=huff(open(sys.argv[1],'rb').read()); open(sys.argv[2],'wb').write(o); print(len(o),o[:16])
