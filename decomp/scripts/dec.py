"""Decompile fn(s) with m2c and annotate constant labels with values. Usage: dec.py fn_... [fn_...]"""
import sys, subprocess, re, glob, os
sys.path.insert(0, os.path.dirname(__file__))
from dolmem import *
ASM = ROOT/'build/asm_m2c_text'
def find(fn):
    for f in glob.glob(str(ASM/'*.s')):
        with open(f) as h:
            if f'.fn {fn},' in h.read(): return f
def annotate(lab):
    if lab not in SYMS: return lab
    a, sec, info = SYMS[lab]
    if 'data:float' in info: return f'{f32(a)!r}f'
    if 'data:double' in info: return f'{f64(a)!r}'
    if 'data:string' in info: return f'"{cstr(a)}"'
    if sec in ('sdata2','rodata') and 'size:0x4' in info and 'data:' not in info:
        return f'{lab}/*{f32(a)!r}?*/'
    return lab
for fn in sys.argv[1:]:
    f = find(fn)
    if f is None:
        print(f'// ===== {fn}: not found'); continue
    out = subprocess.run([str(ROOT.parent/'toolchain/venv/bin/python'), str(ROOT.parent/'toolchain/m2c/m2c.py'), '--target', 'ppc-mwcc-c++', '-f', fn, f] + sorted(glob.glob(str(ROOT/'build/asm_m2c/*.s'))), capture_output=True, text=True)
    txt = out.stdout or out.stderr
    txt = re.sub(r'&?\(?(lbl_[0-9A-F]{8})\)?', lambda m: annotate(m.group(1)) if m.group(0).startswith('lbl') else m.group(0), txt)
    txt = '\n'.join(l for l in txt.splitlines() if not re.match(r'extern (f32|f64) ', l))
    print(f'// ===== {fn} ({os.path.basename(f)})\n{txt}')
