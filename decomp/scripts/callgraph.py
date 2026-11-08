"""Build call graph from asm. Usage: callgraph.py <fn> -> callers/callees ; or --range lo hi"""
import re, glob, sys, collections, json, os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
callees = collections.defaultdict(list); callers = collections.defaultdict(set); datarefs = collections.defaultdict(set)
for f in glob.glob(str(ROOT/'build/HAFE/asm/*.s')):
    fn=None; obj=None
    for l in open(f):
        if l.startswith('.fn '): fn=l.split()[1].rstrip(','); obj=None
        elif l.startswith('.obj '): obj=l.split()[1].rstrip(','); fn=None
        m = re.search(r'\bbl (\w+)', l)
        if m and fn:
            if m.group(1) not in callees[fn]: callees[fn].append(m.group(1))
            callers[m.group(1)].add(fn)
        for m in re.finditer(r'\b(fn_[0-9A-F]{8}|lbl_[0-9A-F]{8})@', l):
            if fn: datarefs[m.group(1)].add(fn)
        m = re.search(r'\.4byte (fn_[0-9A-F]{8})', l)
        if m and obj: datarefs[m.group(1)].add('DATA:'+obj)
for fn in ([] if sys.argv[1:2]==["--range"] else sys.argv[1:]):
    print(fn, '\n  callers:', sorted(callers[fn]), '\n  refs:', sorted(datarefs[fn]), '\n  callees:', callees[fn])
if len(sys.argv) > 1 and sys.argv[1] == '--range':
    lo, hi = int(sys.argv[2],16), int(sys.argv[3],16)
    for l in open(ROOT/'config/HAFE/symbols.txt'):
        m=re.match(r'(\S+) = \.text:0x([0-9A-F]+); // type:function size:0x([0-9A-F]+)',l)
        if m and lo<=int(m[2],16)<hi:
            f=m[1]; print(f, m[3], 'callers', sorted(callers[f])[:6], '| refs', sorted(datarefs[f]-callers[f])[:4], '| callees', [c for c in callees[f] if not c.startswith('_')][:14])
