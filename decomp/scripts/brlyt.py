"""List BRLYT pane tree + text + materials. Usage: brlyt.py file.brlyt [--mat]"""
import struct, sys
d = open(sys.argv[1],'rb').read()
assert d[:4] == b'RLYT'
n = struct.unpack('>H', d[0xE:0x10])[0]
o = struct.unpack('>H', d[0xC:0xE])[0]
depth = 0; out = []
tex=[]; fonts=[]; mats=[]
def cs(b): return b.split(b'\0')[0].decode('latin1')
for _ in range(n):
    mg, sz = d[o:o+4].decode(), struct.unpack('>I', d[o+4:o+8])[0]
    s = d[o:o+sz]
    if mg == 'lyt1':
        print(f"layout {struct.unpack('>ff', s[0xC:0x14])} centered={s[8]}")
    elif mg in ('txl1','fnl1'):
        cnt = struct.unpack('>H', s[8:10])[0]; lst=[]
        for i in range(cnt):
            no = struct.unpack('>I', s[0xC+i*8:0x10+i*8])[0]; lst.append(cs(s[0xC+no:]))
        (tex if mg=='txl1' else fonts).extend(lst); print(mg, lst)
    elif mg == 'mat1':
        cnt = struct.unpack('>H', s[8:10])[0]
        for i in range(cnt):
            mo = struct.unpack('>I', s[0xC+i*4:0x10+i*4])[0]; mats.append(cs(s[mo:mo+20]))
    elif mg in ('pas1','grs1'): depth += 1
    elif mg in ('pae1','gre1'): depth -= 1
    elif mg in ('pan1','pic1','txt1','wnd1','bnd1'):
        flags, origin, alpha = s[8], s[9], s[10]
        name = cs(s[0xC:0x1C]); user = cs(s[0x1C:0x24])
        tr = struct.unpack('>3f', s[0x24:0x30]); rot = struct.unpack('>3f', s[0x30:0x3C]); sc = struct.unpack('>2f', s[0x3C:0x44]); wh = struct.unpack('>2f', s[0x44:0x4C])
        extra=''
        if mg=='txt1':
            blen, slen, mi, fi = struct.unpack('>HHHH', s[0x4C:0x54])
            so = struct.unpack('>I', s[0x58:0x5C])[0]
            txt = s[so:so+slen].decode('utf-16-be','replace').rstrip('\0') if slen else ''
            fsz = struct.unpack('>2f', s[0x64:0x6C])
            extra = f" mat={mats[mi] if mi<len(mats) else mi} font={fonts[fi] if fi<len(fonts) else fi} buf={blen} size={fsz} pos={s[0x54]} align={s[0x55]} text={txt!r}"
        elif mg=='pic1':
            mi = struct.unpack('>H', s[0x5C:0x5E])[0]; extra = f" mat={mats[mi] if mi<len(mats) else mi}"
        elif mg=='wnd1': extra=' (window)'
        vis = 'V' if flags & 1 else '-'
        print(f"{'  '*depth}{mg[:3]} {name:20s} {vis} a={alpha:3d} o={origin} T=({tr[0]:.1f},{tr[1]:.1f}) S=({sc[0]:.2f},{sc[1]:.2f}) R={rot[2]:.0f} WH=({wh[0]:.0f},{wh[1]:.0f}){extra}")
    elif mg == 'grp1':
        name = cs(s[8:0x18]); cnt = struct.unpack('>H', s[0x18:0x1A])[0]
        names = [cs(s[0x1C+i*16:0x2C+i*16]) for i in range(cnt)]
        print(f"{'  '*depth}GROUP {name}: {names}")
    o += sz
