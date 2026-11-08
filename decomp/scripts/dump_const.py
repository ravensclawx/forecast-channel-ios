import sys; sys.path.insert(0, __import__('os').path.dirname(__file__))
from dolmem import *
for arg in sys.argv[1:]:
    a = SYMS[arg][0] if arg in SYMS else int(arg,16)
    print(arg, hex(a), SYMS.get(arg,('','',''))[2], 'f32=',f32(a), 'f64=',f64(a), 'u32=',hex(u32(a) or 0), 'str=',repr(cstr(a))[:60])
