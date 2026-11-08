"""Dump all printable strings in an address range with the covering label. Usage: strdump.py lo hi"""
import sys, re, os, bisect
sys.path.insert(0, os.path.dirname(__file__))
from dolmem import *
lo, hi = int(sys.argv[1],16), int(sys.argv[2],16)
labs = sorted((v[0], k) for k, v in SYMS.items())
starts = [a for a,_ in labs]
blob = read(lo, hi-lo)
for m in re.finditer(rb'[\x20-\x7e\x80-\xff]{3,}', blob):
    a = lo + m.start()
    i = bisect.bisect_right(starts, a)-1
    lab = labs[i][1] if i>=0 else '?'
    print(f'{a:08X} {lab}+{a-labs[i][0]:X} {m.group().decode("latin1")}')
