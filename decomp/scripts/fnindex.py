"""Per-function index of an m2c batch dir: strings, SE ids, named callees. Usage: fnindex.py dir > out"""
import re, sys, glob, os
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.c'))):
    txt = open(f).read()
    for m in re.finditer(r'^(?:[\w?*]+ )+?\**(\w+)\(([^)]*)\) \{\n(.*?)^\}', txt, re.S | re.M):
        name, body = m.group(1), m.group(3)
        strs = sorted(set(re.findall(r'"([A-Za-z_][\w%.\-]*)"', body)))
        se = sorted(set(re.findall(r'Snd_StartSoundHandle\((0x[0-9A-F]+|\d+)\)', body)))
        calls = sorted(set(c for c in re.findall(r'\b([A-Z][A-Za-z0-9]+_[A-Za-z0-9_]+|[A-Z][a-z]+[A-Z]\w+)\(', body)))
        lines = body.count('\n')
        print(f'{name} [{lines}L] str={",".join(strs)[:160]} se={",".join(se)} calls={",".join(calls)[:200]}')
