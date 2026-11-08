"""Map strings in main.dol -> referencing functions (via dtk asm). Usage: xref_strings.py <regex>"""
import re, struct, sys, bisect, glob, collections
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
dol = (ROOT.parent/'orig/main.dol').read_bytes()
offs = struct.unpack('>18I', dol[0:72]); addrs = struct.unpack('>18I', dol[72:144]); sizes = struct.unpack('>18I', dol[144:216])
def file_off(a):
    for o,s,z in zip(offs,addrs,sizes):
        if z and s <= a < s+z: return o + a - s
def addr_of(off):
    for o,s,z in zip(offs,addrs,sizes):
        if z and o <= off < o+z: return s + off - o
# symbol table: label -> (addr,size)
syms = []
for line in (ROOT/'config/HAFE/symbols.txt').read_text().splitlines():
    m = re.match(r'(\S+) = \.(\w+):0x([0-9A-F]+); // type:(\w+)(?: size:0x([0-9A-F]+))?', line)
    if m: syms.append((int(m[3],16), int(m[5] or '0',16), m[1], m[4]))
syms.sort(); starts = [s[0] for s in syms]
def label_for(a):
    i = bisect.bisect_right(starts, a) - 1
    return syms[i] if i >= 0 and syms[i][0] <= a < syms[i][0] + max(syms[i][1],1) else None
# references: label -> set(functions)
refs = collections.defaultdict(set)
for f in glob.glob(str(ROOT/'build/HAFE/asm/*.s')):
    fn = None
    for line in open(f):
        if line.startswith('.fn '): fn = line.split()[1].rstrip(',')
        elif fn:
            for lab in re.findall(r'\b(lbl_[0-9A-F]{8}|\w+)@(?:ha|l|sda21)', line): refs[lab].add(fn)
pat = re.compile(sys.argv[1].encode())
seen = set()
for m in re.finditer(rb'[\x20-\x7e]{4,}', dol):
    if not pat.search(m.group()): continue
    a = addr_of(m.start())
    if a is None: continue
    lab = label_for(a)
    if not lab or lab[2] in seen: continue
    seen.add(lab[2])
    print(f'{lab[2]:14s} {m.group().decode()[:70]!r:74s} <- {", ".join(sorted(refs.get(lab[2], [])))}')
