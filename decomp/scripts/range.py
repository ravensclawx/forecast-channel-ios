import re,sys
lo,hi=int(sys.argv[1],16),int(sys.argv[2],16)
for l in open(__import__('os').path.join(__import__('os').path.dirname(__file__),'../config/HAFE/symbols.txt')):
    m=re.match(r'(\S+) = \.text:0x([0-9A-F]+); // type:function',l)
    if m and lo<=int(m[2],16)<hi: print(m[1])
