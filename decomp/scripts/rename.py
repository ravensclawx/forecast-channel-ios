"""Rename symbols in symbols.txt: rename.py old=new ..."""
import sys, re
from pathlib import Path
p = Path(__file__).resolve().parents[1]/'config/HAFE/symbols.txt'
t = p.read_text(); n=0
for pair in sys.argv[1:]:
    old, new = pair.split('=')
    t2 = re.sub(rf'^{re.escape(old)} = ', f'{new} = ', t, flags=re.M)
    if t2 == t: print('not found', old)
    else: n+=1
    t = t2
p.write_text(t); print('renamed', n)
