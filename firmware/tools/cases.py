#!/usr/bin/env python3
"""List every Keil C51 switch statement (LCALL ?C?CCASE at 0x039D) with its case table.
Table after the call: repeated [addr16 BE, value8], ended by addr 0x0000 + default addr16."""
import sys

code = open(sys.argv[1], 'rb').read()[0xB0:0xF000]
CCASE = 0x039D
sites = [i for i in range(len(code) - 3) if code[i] == 0x12 and (code[i + 1] << 8 | code[i + 2]) == CCASE]
for s in sites:
    p, cases = s + 3, []
    while p + 3 <= len(code):
        addr = code[p] << 8 | code[p + 1]
        if addr == 0:
            default = code[p + 2] << 8 | code[p + 3]
            break
        cases.append((code[p + 2], addr))
        p += 3
    else:
        default = None
    entries = ', '.join(f'0x{v:02X}->L_{a:04X}' for v, a in cases)
    print(f'switch at L_{s:04X}: {entries}; default L_{default:04X}' if default is not None else f'switch at {s:04X}: ?')
    if '--entries' in sys.argv:
        pass
print(','.join(f'{a:X}' for s in sites for a in []), file=sys.stderr)
