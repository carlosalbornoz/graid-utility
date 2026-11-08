#!/usr/bin/env python3 -I
"""Linearize fw code by inlining the compiler's register-shuffle call fragments.

    python3 -I scratch/inline.py START [END] [--depth 6] [--no-inline]
Fragments (targets of LCALL/ACALL that are shorter than --maxlen and end in RET)
are printed inline in braces. Named functions from symbols.txt are never inlined.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import dis8051  # noqa: E402

BIN = os.path.join(HERE, '..', 'G-RAID-firmware-140827300211-4a83278da74eca68.bin')
SYMS = os.path.join(HERE, '..', 'tools', 'symbols.txt')
BASE = 0xB0

code = open(BIN, 'rb').read()

names = {}
for line in open(SYMS):
    line = line.split(';')[0].strip()
    if not line or line.startswith('#'):
        continue
    kind, addr, name = line.split()[:3]
    names[(kind, int(addr, 16))] = name


def name_code(a):
    return names.get(('code', a), f'L_{a:04X}')


def name_x(a):
    return names.get(('x', a), '')


def load():
    """Decode every instruction address reachable by the main disassembler."""
    return {pc: dis8051.decode(code, pc + BASE) for pc in range(BASE, len(code))}


# Pre-decode everything lazily via analyse-like recursion from the fw.asm output instead:
# simpler — parse fw.asm lines.
insns = {}
for l in open(os.path.join(HERE, '..', 'fw.asm')):
    l = l.rstrip()
    if not l.startswith('    '):
        continue
    parts = l.split()
    try:
        pc = int(parts[0], 16)
    except ValueError:
        continue
    txt = l[9:].strip()
    extra = ''
    ln = 1
    d = dis8051.decode(code, pc + BASE)
    if d:
        _, ln0, _, _ = d
        ln = ln0
    if txt.startswith('LCALL L_036C'):
        ln = 7
        extra = '  ; = long 0x' + code[pc + BASE + 3:pc + BASE + 7].hex()
    targets = [int(t, 16) for t in re.findall(r'L_([0-9A-F]{4})', txt)]
    if re.search(r'\b(LCALL|ACALL) L_', txt):
        kind = 'call'
    elif re.search(r'\b(SJMP|AJMP|LJMP) L_|JMP @', txt):
        kind = 'jmp'
    elif re.search(r'\b(JC|JNC|JB|JNB|JBC|JZ|JNZ|CJNE|DJNZ) L_', txt):
        kind = 'cjmp'
    elif re.search(r'\b(RET|RETI)\b', txt):
        kind = 'ret'
    else:
        kind = None
    insns[pc] = (txt + extra, ln, targets, kind)


def frag_len(a, seen=None):
    """Length of the straight-line fragment at a until RET/first branch, and whether it ends in RET."""
    seen = seen or set()
    pc = a
    n = 0
    while pc in insns and pc not in seen and n < 64:
        seen.add(pc)
        txt, ln, targets, kind = insns[pc]
        n += ln
        if kind == 'ret':
            return n, True
        if kind in ('cjmp', 'ijmp'):
            return n, False
        if kind == 'jmp':
            # tail jump = still part of fragment if short
            t = targets[0] if targets else None
            if t and abs(t - pc) < 0x40:
                pc = t
                continue
            return n, False
        pc += ln
    return n, False


def render(a, end, depth, maxlen, seen=None, ind=0):
    out = []
    pc = a
    while pc in insns and pc < end:
        txt, ln, targets, kind = insns[pc]
        tag = name_x(0)  # placeholder
        m = None
        if txt.startswith('MOV DPTR, #0x'):
            m = int(txt.split('#0x')[1].split()[0], 16)
        nx = name_x(m) if m is not None and m < 0x10000 else ''
        ann = f'   ; {nx}' if nx else ''
        nm = names.get(('code', pc))
        if nm:
            out.append(' ' * ind + f'{nm}:')
        out.append(' ' * ind + f'{pc:04X}  {txt}{ann}')
        if kind == 'call' and targets:
            t = targets[0]
            fl, ends_ret = frag_len(t)
            if depth > 0 and fl <= maxlen and ('code', t) not in names:
                out.extend(render(t, t + fl + 1, depth - 1, maxlen, ind=ind + 6))
                # the call's own effect is the fragment; note fallthrough handled by callee code
                out.append(' ' * ind + ' ' * 6 + ';; (inlined; DPTR/A effects as shown)')
            else:
                out.append(' ' * ind + f'      -> {name_code(t)}')
        if kind == 'ret':
            break
        if kind == 'jmp':
            t = targets[0]
            if t < pc or t >= end:
                out.append(' ' * ind + f'      ;; jmp out to {name_code(t)}')
                break
        pc += ln
    return out


args = [a for a in sys.argv[1:] if not a.startswith('--')]
depth = int(sys.argv[sys.argv.index('--depth') + 1]) if '--depth' in sys.argv else 6
maxlen = int(sys.argv[sys.argv.index('--maxlen') + 1]) if '--maxlen' in sys.argv else 20
start = int(args[0], 16)
end = int(args[1], 16) if len(args) > 1 else start + 0x100
print('\n'.join(render(start, end, depth, maxlen)))
