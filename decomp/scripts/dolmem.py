"""DOL memory access helpers + symbol table."""
import struct, re, bisect
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
DOL = (ROOT.parent/'orig/main.dol').read_bytes()
_o = struct.unpack('>18I', DOL[0:72]); _a = struct.unpack('>18I', DOL[72:144]); _s = struct.unpack('>18I', DOL[144:216])
def off(a):
    for o,s,z in zip(_o,_a,_s):
        if z and s <= a < s+z: return o + a - s
def read(a, n):
    o = off(a); return None if o is None else DOL[o:o+n]
def f32(a): b=read(a,4); return None if b is None else struct.unpack('>f',b)[0]
def f64(a): b=read(a,8); return None if b is None else struct.unpack('>d',b)[0]
def u32(a): b=read(a,4); return None if b is None else struct.unpack('>I',b)[0]
def cstr(a):
    o=off(a)
    if o is None: return None
    e=DOL.index(b'\0',o); return DOL[o:e].decode('latin1')
SYMS = {}
for line in (ROOT/'config/HAFE/symbols.txt').read_text().splitlines():
    m = re.match(r'(\S+) = \.(\w+):0x([0-9A-F]+); // (.*)', line)
    if m: SYMS[m[1]] = (int(m[3],16), m[2], m[4])
