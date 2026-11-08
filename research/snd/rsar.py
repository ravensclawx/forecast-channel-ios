import struct,sys
d=open(sys.argv[1],'rb').read()
u32=lambda o:struct.unpack('>I',d[o:o+4])[0]; s32=lambda o:struct.unpack('>i',d[o:o+4])[0]
u16=lambda o:struct.unpack('>H',d[o:o+2])[0]; u8=lambda o:d[o]
symb,info,file_=u32(0x10),u32(0x18),u32(0x20)
sb=symb+8
strtab=sb+u32(symb+8)
nstr=u32(strtab); strs=[]
for i in range(nstr):
    o=sb+u32(strtab+4+i*4); e=d.index(b'\0',o); strs.append(d[o:e].decode())
ib=info+8
def ref(o): return (u8(o),u8(o+1),u32(o+4))
def table(o):
    n=u32(o); return [ib+u32(o+4+i*8+4) for i in range(n)]
snd=table(ib+u32(ib+4)); bank=table(ib+u32(ib+12)); ply=table(ib+u32(ib+20)); files=table(ib+u32(ib+28)); grp=table(ib+u32(ib+36))
print('strings',nstr,'sounds',len(snd),'banks',len(bank),'players',len(ply),'files',len(files),'groups',len(grp))
T={1:'SEQ',2:'STRM',3:'WAVE'}
for i,o in enumerate(snd):
    sid,fid,pid=u32(o),u32(o+4),u32(o+8); vol,prio,typ=u8(o+0x14),u8(o+0x15),u8(o+0x16)
    det=ib+u32(o+0x1C)
    extra=''
    if typ==1: extra='label=%d bank=%d track=%x'%(u32(det),u32(det+4),u32(det+8))
    if typ==3: extra='sub=%d'%s32(det)
    print(i, strs[sid] if sid<nstr else sid, T.get(typ,typ),'file',fid,'player',pid,'vol',vol,'prio',prio,extra, 'user',u32(o+0x24))
for i,o in enumerate(bank): print('bank',i,strs[u32(o)],'file',u32(o+4))
for i,o in enumerate(ply): print('player',i,strs[u32(o)],'count',u8(o+4),'heap',u32(o+8))
for i,o in enumerate(files): print('file',i,'size',u32(o),'wsize',u32(o+4))
for i,o in enumerate(grp): print('group',i,strs[u32(o)] if u32(o)<nstr else u32(o),'off',hex(u32(o+0x10)),'size',hex(u32(o+0x14)),'woff',hex(u32(o+0x18)),'wsize',hex(u32(o+0x1C)), 'items', u32(ib+u32(o+0x24)))

def files_of_group(gi):
    o=grp[gi]; base=u32(o+0x10); wbase=u32(o+0x18)
    t=ib+u32(o+0x24); n=u32(t); out={}
    for i in range(n):
        it=ib+u32(t+4+i*8+4)
        out[u32(it)]=(base+u32(it+4),u32(it+8),wbase+u32(it+12),u32(it+16))
    return out
F=files_of_group(0)
for k,v in sorted(F.items()): print('gfile',k,[hex(x) for x in v], d[v[0]:v[0]+4])
import os
os.makedirs('out',exist_ok=True)
for k,(o,s,wo,ws) in F.items():
    open('out/file%d.bin'%k,'wb').write(d[o:o+s])
    if ws: open('out/file%d.wave'%k,'wb').write(d[wo:wo+ws])
