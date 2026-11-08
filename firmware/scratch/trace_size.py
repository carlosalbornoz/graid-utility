#!/usr/bin/env python3 -I
"""Trace the array-size computation: log every write to the scratch bytes/temps."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import emu8051

WATCH = list(range(0x06AF, 0x06B5)) + [0x0502, 0x0506] + \
    [0x0A35, 0x0A36, 0x0A37, 0x0A38, 0x0A39, 0x0A3A, 0x0A3B, 0x0A3C, 0x0A3D,
     0x0A3E, 0x0A3F, 0x0A40, 0x0A41, 0x0A42, 0x0A43, 0x0A44, 0x0A45, 0x0A46, 0x0A47, 0x0A48]


def main():
    SZ = 0x1D1C0BEAF
    m = emu8051.Machine(max_steps=300000)
    for i in range(2):
        b = i * 0xC2
        m.xdata[b + 5:b + 9] = (SZ & 0xFFFFFFFF).to_bytes(4, 'big')     # low
        m.xdata[b + 9:b + 13] = (SZ >> 32).to_bytes(4, 'big')           # high
    m.xdata[0x0A28:0x0A2B] = bytes([0, 1, 0xFF])
    m.xdata[0x049B] = int(sys.argv[1]) if len(sys.argv) > 1 else 1     # ALIGN_FLAG
    m.xdata[0x0498] = 2
    m.xdata[0x0499] = 2

    orig = m.step
    log = []

    def step():
        pc = m.pc
        op = m.code[pc]
        if op == 0xF0 and m.dptr in WATCH:  # MOVX @DPTR,A
            log.append((pc, m.dptr, m.acc))
        orig()
        # also catch helper-stores via fragments that end with F0 after computing DPTR
    m.step = step
    m.run(0x9FBE, regs={'r7': 0, 'r3': 1, 'r2': 0x0A, 'r1': 0x28})
    names = {0x06AF: 'bAF', 0x06B0: 'bB0', 0x06B1: 'bB1', 0x06B2: 'bB2', 0x06B3: 'bB3',
             0x06B4: 'bB4', 0x0502: 'SZhi', 0x0506: 'SZlo'}
    for pc, a, v in log:
        nm = names.get(a, f'{a:04X}')
        print(f'{pc:04X}: [{nm}] = {v:02X}')


if __name__ == '__main__':
    main()
