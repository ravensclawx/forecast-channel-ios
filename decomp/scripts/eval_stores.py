"""Evaluate constant byte stores `lbl_X.unkNN = 0xYY;` in a function's m2c output -> table dump.
Usage: eval_stores.py fn label size"""
import subprocess, sys, re, os
fn, lab, size = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
out = subprocess.run([sys.executable, '-I', os.path.join(os.path.dirname(__file__), 'dec.py'), fn], capture_output=True, text=True).stdout
mem = bytearray(size)
for m in re.finditer(lab + r'\.unk([0-9A-F]+) = (?:\(s32\) )?(0x[0-9A-F]+|\d+);', out):
    o = int(m.group(1), 16); v = int(m.group(2), 0)
    if o < size: mem[o] = v & 0xFF
for i in range(0, size, 4):
    if i % 0x3C == 0: print(f'-- scheme {i // 0x3C}')
    print(f'+{i % 0x3C:02X} {mem[i]:02X}{mem[i+1]:02X}{mem[i+2]:02X}{mem[i+3]:02X}')
