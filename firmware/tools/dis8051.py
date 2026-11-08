#!/usr/bin/env python3
"""Small 8051 disassembler for the G-RAID ASM1092R firmware dump.

Recursive descent from the reset/interrupt vectors plus every LCALL/LJMP target, so data
tables aren't decoded as code. Output: one line per instruction with labels and xrefs.

    python3 -I dis8051.py <image.bin> [--base 0xB0] [--end 0xF000] > out.asm
"""
import sys

SFR = {0x80: 'P0', 0x81: 'SP', 0x82: 'DPL', 0x83: 'DPH', 0x87: 'PCON', 0x88: 'TCON', 0x89: 'TMOD',
       0x8A: 'TL0', 0x8B: 'TL1', 0x8C: 'TH0', 0x8D: 'TH1', 0x90: 'P1', 0x98: 'SCON', 0x99: 'SBUF',
       0xA0: 'P2', 0xA8: 'IE', 0xB0: 'P3', 0xB8: 'IP', 0xD0: 'PSW', 0xE0: 'ACC', 0xF0: 'B'}


def dname(a):
    return SFR.get(a, f'0x{a:02X}') if a >= 0x80 else f'0x{a:02X}'


def bname(b):
    if b < 0x80:
        return f'0x{0x20 + b // 8:02X}.{b % 8}'
    base = b & 0xF8
    return f'{SFR.get(base, f"0x{base:02X}")}.{b & 7}'


def decode(code, pc):
    """Return (mnemonic text, length, targets, kind) for the instruction at pc.
    kind: 'call', 'jmp' (unconditional), 'cjmp' (conditional), 'ret', 'ijmp' or None."""
    op = code[pc]
    b1 = code[pc + 1] if pc + 1 < len(code) else 0
    b2 = code[pc + 2] if pc + 2 < len(code) else 0
    rel = lambda off, ln: (pc + ln + (off - 256 if off > 127 else off)) & 0xFFFF
    lo, hi = op & 0x0F, op >> 4
    rn = f'R{op & 7}'
    ri = f'@R{op & 1}'

    if lo == 1:  # AJMP / ACALL
        t = ((pc + 2) & 0xF800) | ((op >> 5) << 8) | b1
        return (f'ACALL L_{t:04X}' if op & 0x10 else f'AJMP L_{t:04X}', 2, [t],
                'call' if op & 0x10 else 'jmp')
    table = {
        0x00: ('NOP', 1), 0x02: (f'LJMP L_{b1 << 8 | b2:04X}', 3), 0x03: ('RR A', 1),
        0x04: ('INC A', 1), 0x05: (f'INC {dname(b1)}', 2),
        0x10: (f'JBC {bname(b1)}, L_{rel(b2, 3):04X}', 3), 0x12: (f'LCALL L_{b1 << 8 | b2:04X}', 3),
        0x13: ('RRC A', 1), 0x14: ('DEC A', 1), 0x15: (f'DEC {dname(b1)}', 2),
        0x20: (f'JB {bname(b1)}, L_{rel(b2, 3):04X}', 3), 0x22: ('RET', 1), 0x23: ('RL A', 1),
        0x24: (f'ADD A, #0x{b1:02X}', 2), 0x25: (f'ADD A, {dname(b1)}', 2),
        0x30: (f'JNB {bname(b1)}, L_{rel(b2, 3):04X}', 3), 0x32: ('RETI', 1), 0x33: ('RLC A', 1),
        0x34: (f'ADDC A, #0x{b1:02X}', 2), 0x35: (f'ADDC A, {dname(b1)}', 2),
        0x40: (f'JC L_{rel(b1, 2):04X}', 2), 0x42: (f'ORL {dname(b1)}, A', 2),
        0x43: (f'ORL {dname(b1)}, #0x{b2:02X}', 3), 0x44: (f'ORL A, #0x{b1:02X}', 2),
        0x45: (f'ORL A, {dname(b1)}', 2),
        0x50: (f'JNC L_{rel(b1, 2):04X}', 2), 0x52: (f'ANL {dname(b1)}, A', 2),
        0x53: (f'ANL {dname(b1)}, #0x{b2:02X}', 3), 0x54: (f'ANL A, #0x{b1:02X}', 2),
        0x55: (f'ANL A, {dname(b1)}', 2),
        0x60: (f'JZ L_{rel(b1, 2):04X}', 2), 0x62: (f'XRL {dname(b1)}, A', 2),
        0x63: (f'XRL {dname(b1)}, #0x{b2:02X}', 3), 0x64: (f'XRL A, #0x{b1:02X}', 2),
        0x65: (f'XRL A, {dname(b1)}', 2),
        0x70: (f'JNZ L_{rel(b1, 2):04X}', 2), 0x72: (f'ORL C, {bname(b1)}', 2),
        0x73: ('JMP @A+DPTR', 1), 0x74: (f'MOV A, #0x{b1:02X}', 2),
        0x75: (f'MOV {dname(b1)}, #0x{b2:02X}', 3),
        0x80: (f'SJMP L_{rel(b1, 2):04X}', 2), 0x82: (f'ANL C, {bname(b1)}', 2),
        0x83: ('MOVC A, @A+PC', 1), 0x84: ('DIV AB', 1), 0x85: (f'MOV {dname(b2)}, {dname(b1)}', 3),
        0x90: (f'MOV DPTR, #0x{b1 << 8 | b2:04X}', 3), 0x92: (f'MOV {bname(b1)}, C', 2),
        0x93: ('MOVC A, @A+DPTR', 1), 0x94: (f'SUBB A, #0x{b1:02X}', 2), 0x95: (f'SUBB A, {dname(b1)}', 2),
        0xA0: (f'ORL C, /{bname(b1)}', 2), 0xA2: (f'MOV C, {bname(b1)}', 2), 0xA3: ('INC DPTR', 1),
        0xA4: ('MUL AB', 1), 0xA5: ('DB 0xA5', 1),
        0xB0: (f'ANL C, /{bname(b1)}', 2), 0xB2: (f'CPL {bname(b1)}', 2), 0xB3: ('CPL C', 1),
        0xB4: (f'CJNE A, #0x{b1:02X}, L_{rel(b2, 3):04X}', 3), 0xB5: (f'CJNE A, {dname(b1)}, L_{rel(b2, 3):04X}', 3),
        0xC0: (f'PUSH {dname(b1)}', 2), 0xC2: (f'CLR {bname(b1)}', 2), 0xC3: ('CLR C', 1),
        0xC4: ('SWAP A', 1), 0xC5: (f'XCH A, {dname(b1)}', 2),
        0xD0: (f'POP {dname(b1)}', 2), 0xD2: (f'SETB {bname(b1)}', 2), 0xD3: ('SETB C', 1),
        0xD4: ('DA A', 1), 0xD5: (f'DJNZ {dname(b1)}, L_{rel(b2, 3):04X}', 3),
        0xE0: ('MOVX A, @DPTR', 1), 0xE4: ('CLR A', 1), 0xE5: (f'MOV A, {dname(b1)}', 2),
        0xF0: ('MOVX @DPTR, A', 1), 0xF4: ('CPL A', 1), 0xF5: (f'MOV {dname(b1)}, A', 2),
    }
    if op in table:
        txt, ln = table[op]
    elif lo in (6, 7) or lo >= 8:
        reg = ri if lo in (6, 7) else rn
        groups = {0x0: f'INC {reg}', 0x1: f'DEC {reg}', 0x2: f'ADD A, {reg}', 0x3: f'ADDC A, {reg}',
                  0x4: f'ORL A, {reg}', 0x5: f'ANL A, {reg}', 0x6: f'XRL A, {reg}',
                  0x7: (f'MOV {reg}, #0x{b1:02X}', 2), 0x8: (f'MOV {dname(b1)}, {reg}', 2),
                  0x9: f'SUBB A, {reg}', 0xA: (f'MOV {reg}, {dname(b1)}', 2),
                  0xB: (f'CJNE {reg}, #0x{b1:02X}, L_{rel(b2, 3):04X}', 3), 0xC: f'XCH A, {reg}',
                  0xE: f'MOV A, {reg}', 0xF: f'MOV {reg}, A'}
        if hi == 0xD:
            if lo in (6, 7):
                txt, ln = f'XCHD A, {reg}', 1
            else:
                txt, ln = f'DJNZ {reg}, L_{rel(b1, 2):04X}', 2
        else:
            g = groups[hi]
            txt, ln = (g, 1) if isinstance(g, str) else g
    elif op in (0xE2, 0xE3):
        txt, ln = f'MOVX A, {ri}', 1
    elif op in (0xF2, 0xF3):
        txt, ln = f'MOVX {ri}, A', 1
    else:
        txt, ln = f'DB 0x{op:02X}', 1

    targets, kind = [], None
    if op == 0x02:
        targets, kind = [b1 << 8 | b2], 'jmp'
    elif op == 0x12:
        targets, kind = [b1 << 8 | b2], 'call'
    elif op == 0x80:
        targets, kind = [rel(b1, 2)], 'jmp'
    elif op in (0x40, 0x50, 0x60, 0x70) or (hi == 0xD and lo >= 8):
        targets, kind = [rel(b1, 2)], 'cjmp'
    elif op in (0x10, 0x20, 0x30, 0xB4, 0xB5, 0xD5) or (hi == 0xB and lo >= 6):
        targets, kind = [rel(b2, 3)], 'cjmp'
    elif op in (0x22, 0x32):
        kind = 'ret'
    elif op == 0x73:
        kind = 'ijmp'
    return txt, ln, targets, kind


def analyse(code, entries):
    insns, calls, xrefs = {}, set(), {}
    todo = list(entries)
    while todo:
        pc = todo.pop()
        while 0 <= pc < len(code) and pc not in insns:
            txt, ln, targets, kind = decode(code, pc)
            insns[pc] = (txt, ln)
            # Keil runtime helpers that take inline data after the call.
            if txt == 'LCALL L_036C':
                insns[pc] = (txt + '  ; + inline long 0x' + code[pc + 3:pc + 7].hex(), 7)
                ln = 7
            if txt == 'LCALL L_039D':
                kind = 'ret'  # ?C?CCASE: a case table follows, not code
            for t in targets:
                xrefs.setdefault(t, set()).add(pc)
                if t < len(code):
                    todo.append(t)
                if kind == 'call':
                    calls.add(t)
            if kind in ('jmp', 'ret', 'ijmp'):
                break
            pc += ln
    return insns, calls, xrefs


def main():
    args = sys.argv[1:]
    path = args[0]
    base = int(args[args.index('--base') + 1], 16) if '--base' in args else 0xB0
    end = int(args[args.index('--end') + 1], 16) if '--end' in args else 0xF000
    code = open(path, 'rb').read()[base:end]
    vectors = [0x00, 0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B]
    extra = [int(x, 16) for x in args[args.index('--entry') + 1].split(',')] if '--entry' in args else []
    insns, calls, xrefs = analyse(code, vectors + extra)
    for pc in sorted(insns):
        txt, ln = insns[pc]
        if pc in xrefs or pc in calls:
            tag = 'FUNC' if pc in calls else 'LBL'
            refs = ' '.join(f'{r:04X}' for r in sorted(xrefs.get(pc, ())))[:120]
            print(f'\n; {tag} L_{pc:04X}   xrefs: {refs}')
            print(f'L_{pc:04X}:')
        raw = code[pc:pc + ln].hex()
        print(f'    {pc:04X}  {raw:<8}  {txt}')
    covered = sum(ln for _, ln in insns.values())
    print(f'\n; {len(insns)} instructions, {covered} bytes of {len(code)} decoded, {len(calls)} functions',
          file=sys.stderr)


if __name__ == '__main__':
    main()
