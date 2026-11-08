"""Dump N words at addr/label, naming function/label pointers. Usage: words.py <lbl|hex> [n]"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from dolmem import *
byaddr = {v[0]: k for k, v in SYMS.items()}
a = SYMS[sys.argv[1]][0] if sys.argv[1] in SYMS else int(sys.argv[1], 16)
n = int(sys.argv[2]) if len(sys.argv) > 2 else 16
for i in range(n):
    w = u32(a + i*4)
    nm = byaddr.get(w, '')
    s = ''
    if not nm and 0x80000000 <= w < 0x81800000:
        st = cstr(w)
        if st and len(st) > 2 and st.isprintable(): s = repr(st)
    print(f'{a+i*4:08X} +{i*4:03X}: {w:08X} {nm} {s}')
