#!/usr/bin/env python3
"""Browse fw.asm with names from symbols.txt.

    python3 -I tools/show.py range D739 D8A2      # instructions in [start, end)
    python3 -I tools/show.py func A84E            # from a label to the next RET/LJMP-out (rough)
    python3 -I tools/show.py xrefs 04F0           # instructions mentioning XDATA/code 0x04F0
    python3 -I tools/show.py callers A84E         # LCALL/ACALL/LJMP sites targeting L_A84E
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASM = os.path.join(HERE, '..', 'fw.asm')
SYMS = os.path.join(HERE, 'symbols.txt')

names = {}
for line in open(SYMS):
    line = line.split(';')[0].strip()
    if not line or line.startswith('#'):
        continue
    kind, addr, name = line.split()[:3]
    names[(kind, int(addr, 16))] = name

lines = [l for l in open(ASM).read().splitlines() if re.match(r'\s{4}[0-9A-F]{4}\s', l)]
addr_of = lambda l: int(l.split()[0], 16)


def label(l):
    l = re.sub(r'L_([0-9A-F]{4})', lambda m: names.get(('code', int(m.group(1), 16)), m.group(0)), l)
    m = re.search(r'#0x([0-9A-F]{4})', l)
    if m and ('x', int(m.group(1), 16)) in names:
        l += f'    ; {names[("x", int(m.group(1), 16))]}'
    a = addr_of(l)
    if ('code', a) in names:
        l = f'\n{names[("code", a)]}:\n' + l
    return l


cmd, *rest = sys.argv[1:]
if cmd == 'range':
    a, b = int(rest[0], 16), int(rest[1], 16)
    print('\n'.join(label(l) for l in lines if a <= addr_of(l) < b))
elif cmd == 'func':
    a = int(rest[0], 16)
    out = [l for l in lines if addr_of(l) >= a]
    for l in out[:400]:
        print(label(l))
        if re.search(r'\b(RET|RETI)\b', l):
            break
elif cmd == 'xrefs':
    v = rest[0].upper().zfill(4)
    for l in lines:
        if f'0x{v}' in l or f'L_{v}' in l:
            print(label(l))
elif cmd == 'callers':
    v = rest[0].upper().zfill(4)
    for l in lines:
        if re.search(rf'(LCALL|ACALL|LJMP|AJMP|SJMP) L_{v}\b', l):
            print(label(l))
else:
    print(__doc__)
