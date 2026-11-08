"""Batch-decompile asm files in a text range with m2c; resolve label(+off) to strings/floats.
Usage: decall.py lo hi outdir"""
import sys, subprocess, re, glob, os
sys.path.insert(0, os.path.dirname(__file__))
from dolmem import *
ASM = ROOT/'build/asm_m2c_text'
lo, hi, outdir = int(sys.argv[1],16), int(sys.argv[2],16), sys.argv[3]
os.makedirs(outdir, exist_ok=True)
data = sorted(glob.glob(str(ROOT/'build/asm_m2c/*.s')))
def strat(a):
    s = cstr(a)
    if s and len(s) >= 1 and all(32 <= ord(c) < 127 or ord(c) >= 160 for c in s): return s
    return None
def lab_addr(l): return SYMS[l][0] if l in SYMS else None
def ann(lab, off=0):
    a = lab_addr(lab)
    if a is None: return lab + (f' + 0x{off:X}' if off else '')
    a += off
    info = SYMS[lab][2]
    s = strat(a)
    if s is not None and ('string' in info or off): return f'"{s}"'
    if off == 0 and 'data:float' in info: return f'{f32(a)!r}f'
    if off == 0 and 'data:double' in info: return f'{f64(a)!r}'
    if off == 0 and SYMS[lab][1] in ('sdata2','rodata') and 'size:0x4' in info: return f'{lab}/*{f32(a)!r}|{u32(a):#x}*/'
    return lab + (f' + 0x{off:X}' if off else '')
files = []
for f in sorted(glob.glob(str(ASM/'auto_03_*_text.s'))+glob.glob(str(ASM/'auto_fn_*_text.s'))):
    m = re.search(r'([0-9A-F]{8})', os.path.basename(f).split('_text')[0][-8:])
    if not m: continue
    txt = open(f).read()
    addrs = [int(x,16) for x in re.findall(r'^/\* ([0-9A-F]{8}) ', txt, re.M)]
    if addrs and lo <= addrs[0] < hi: files.append((addrs[0], f))
for a, f in sorted(files):
    out = subprocess.run([str(ROOT.parent/'toolchain/venv/bin/python'), str(ROOT.parent/'toolchain/m2c/m2c.py'),
                          '--target', 'ppc-mwcc-c++', '--no-casts', f] + data, capture_output=True, text=True)
    txt = out.stdout + ('\n/* M2C STDERR:\n' + out.stderr[-3000:] + '*/' if out.returncode else '')
    # m2c renders string labels as "..." literals; map literal -> address by recomputing from labels referenced
    # 1) direct (lbl + 0xNN) patterns
    txt = re.sub(r'\(?&?(lbl_[0-9A-F]{8})\)? \+ 0x([0-9A-F]+)', lambda m: ann(m.group(1), int(m.group(2),16)), txt)
    txt = re.sub(r'&?(lbl_[0-9A-F]{8})\b', lambda m: ann(m.group(1)), txt)
    # 2) var = "str"; ... var + 0xNN  -> resolve via string literal address lookup
    litaddr = {}
    for lab,(ad,sec,info) in SYMS.items():
        if 'string' in info or sec in ('rodata','data'):
            s = strat(ad)
            if s: litaddr.setdefault(s, ad)
    def fix_func(body):
        vars_ = dict(re.findall(r'(\w+) = "([^"\n]*)";', body))
        def rep(m):
            v, off = m.group(1), int(m.group(2),16)
            if v in vars_ and vars_[v] in litaddr:
                s = strat(litaddr[vars_[v]] + off)
                if s is not None: return f'"{s}"'
            return m.group(0)
        return re.sub(r'\b(\w+) \+ 0x([0-9A-F]+)\b', rep, body)
    txt = fix_func(txt)
    txt = '\n'.join(l for l in txt.splitlines() if not re.match(r'extern (f32|f64) ', l) and 'unable to generate initializer' not in l)
    open(os.path.join(outdir, f'{a:08X}_{os.path.basename(f)[:-2]}.c'), 'w').write(txt)
    print(f'{a:08X} {os.path.basename(f)} {len(txt.splitlines())} lines')
