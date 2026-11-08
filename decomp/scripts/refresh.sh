#!/bin/sh
# Re-split after symbol renames and rebuild the m2c-friendly asm copies.
cd "$(dirname "$0")/.." && ../toolchain/dtk dol split config/HAFE/config.yml build/HAFE >/dev/null 2>&1 && python3 -I - <<'PY'
import re, glob, os
os.makedirs('build/asm_m2c', exist_ok=True); os.makedirs('build/asm_m2c_text', exist_ok=True)
targets=set()
for f in glob.glob('build/HAFE/asm/auto_0[6-9]_*.s')+glob.glob('build/HAFE/asm/auto_1[0-2]_*.s'):
    t=open(f).read()
    t=re.sub(r'\.4byte (\w+)\+0x([0-9A-F]+)', lambda m: m.group(0), t)
    open('build/asm_m2c/'+os.path.basename(f),'w').write(t)
# resolve fn+off -> .L_addr using symbol table
syms={}
for l in open('config/HAFE/symbols.txt'):
    m=re.match(r'(\S+) = \.\w+:0x([0-9A-F]+);',l)
    if m: syms[m.group(1)]=int(m.group(2),16)
for f in glob.glob('build/asm_m2c/*.s'):
    t=open(f).read()
    def rep(m):
        if m.group(1) not in syms: return m.group(0)
        a=syms[m.group(1)]+int(m.group(2),16); targets.add(f'{a:08X}'); return f'.4byte .L_{a:08X}'
    open(f,'w').write(re.sub(r'\.4byte (\w+)\+0x([0-9A-F]+)', rep, t))
for f in glob.glob('build/HAFE/asm/*.s'):
    if os.path.basename(f) in os.listdir('build/asm_m2c'): continue
    have=set(re.findall(r'^\.L_([0-9A-F]{8}):', open(f).read(), re.M)); out=[]
    for l in open(f):
        m=re.match(r'/\* ([0-9A-F]{8}) ', l)
        if m and m.group(1) in targets and m.group(1) not in have: out.append(f'.L_{m.group(1)}:\n')
        out.append(l)
    open('build/asm_m2c_text/'+os.path.basename(f),'w').writelines(out)
print('refreshed')
PY
