"""For functions in [lo,hi): list data objects holding pointers to them (vtables/PTMF/callbacks). Usage: lo hi"""
import re, glob, sys, collections, os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
lo, hi = int(sys.argv[1],16), int(sys.argv[2],16)
refs = collections.defaultdict(list)
for f in glob.glob(str(ROOT/'build/HAFE/asm/auto_0[6-9]*.s'))+glob.glob(str(ROOT/'build/HAFE/asm/auto_1*.s')):
    obj=None; idx=0
    for l in open(f):
        if l.startswith('.obj '): obj=l.split()[1].rstrip(','); idx=0
        m = re.search(r'\.4byte (fn_([0-9A-F]{8}))', l)
        if m and obj:
            a=int(m.group(2),16)
            if lo<=a<hi: refs[obj].append((idx, m.group(1)))
        if obj and re.search(r'\.(4byte|float|byte|2byte|double|string)', l): idx+=1
for obj in sorted(refs): print(obj, ' '.join(f'{fn}' for i,fn in refs[obj]))
