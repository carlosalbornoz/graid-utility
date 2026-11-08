#!/usr/bin/env python3 -I
"""Tiny 8051 emulator for the G-RAID firmware dump (static analysis aid).

Runs code from the image with a controlled XDATA/IRAM environment so RAID math,
metadata builds and reply builders can be observed without hardware.

    from emu8051 import run
    m = run(0xA84E, {'regs': {'r7': 0}, 'xdata': {0x0000: ...}})
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, '..', 'G-RAID-firmware-140827300211-4a83278da74eca68.bin')
IMAGE = open(BIN, 'rb').read()
BASE = 0xB0  # code address 0 lives at file offset 0xB0
CODESIZE = 0xF000


class Machine:
    def __init__(self, trace=None, max_steps=2_000_000):
        self.xdata = bytearray(0x10000)
        self.iram = bytearray(0x100)
        self.sfr = bytearray(0x100)
        self.code = bytearray(CODESIZE)
        self.code[:min(len(IMAGE) - BASE, CODESIZE)] = IMAGE[BASE:BASE + CODESIZE]
        self.acc = 0
        self.b = 0
        self.dptr = 0
        self.sp = 0x07
        self.psw = 0  # bit0 C, bit2 OV ... we keep C separately below
        self.c = 0
        self.rs = 0  # register bank
        self.steps = 0
        self.max_steps = max_steps
        self.pc = 0
        self.call_depth = 0
        self.trace = trace if trace is not None else []
        self.halted = None
        self.calls = []
        self.io_reads = []   # (addr, value) XDATA reads of 'device' regs
        self.io_writes = []
        self.hw_override = None  # if set, reads >=0xEF00 return this byte

    # -- register banks ------------------------------------------------
    def r(self, i):
        return self.iram[self.rs * 8 + i]

    def setr(self, i, v):
        self.iram[self.rs * 8 + i] = v & 0xFF

    # -- helpers -------------------------------------------------------
    def fetch(self):
        v = self.code[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        return self.fetch() << 8 | self.fetch()

    def rd_code(self, a):
        return self.code[a] if a < len(self.code) else 0

    def rd_iram(self, a):
        a &= 0xFF
        if a < 0x80:
            return self.iram[a]
        if a == 0xE0:
            return self.acc
        if a == 0xF0:
            return self.b
        return self.sfr[a]

    def wr_iram(self, a, v):
        a &= 0xFF
        v &= 0xFF
        if a < 0x80:
            self.iram[a] = v
            return
        if a == 0xE0:
            self.acc = v
            return
        if a == 0xF0:
            self.b = v
            return
        self.sfr[a] = v
        if a in (0x82, 0x83):  # DPL/DPH
            self.dptr = self.sfr[0x83] << 8 | self.sfr[0x82]

    def bitaddr(self, b):
        if b < 0x80:
            return (0x20 + b // 8, 1 << (b % 8))
        return (0x80 + (b & 0xF8) if False else (b & 0xF8) | 0x80, 1 << (b & 7))

    def rd_bit(self, b):
        a, m = self.bitaddr(b)
        return 1 if self.rd_iram(a) & m else 0

    def wr_bit(self, b, v):
        a, m = self.bitaddr(b)
        cur = self.rd_iram(a)
        self.wr_iram(a, (cur | m) if v else (cur & ~m))

    def set_psw_flags(self, result):
        # Z, P, N-ish; we only maintain C separately + PSW bits used by code
        self.sfr[0xD0] = (self.sfr[0xD0] & 0x3F) | (self.c << 7)

    # -- ALU -----------------------------------------------------------
    def add(self, other, carry=0):
        a = self.acc
        r = a + other + carry
        self.c = 1 if r > 0xFF else 0
        ov = 1 if (~(a ^ other) & (a ^ r) & 0x80) else 0
        self.acc = r & 0xFF
        self.wr_iram(0xD0, (self.rd_iram(0xD0) & 0x3F) | (self.c << 7) | (ov << 2))

    def subb(self, other):
        a = self.acc
        r = a - other - self.c
        self.c = 1 if r < 0 else 0
        ov = 1 if ((a ^ other) & (a ^ (r & 0xFF)) & 0x80) else 0
        self.acc = r & 0xFF
        self.wr_iram(0xD0, (self.rd_iram(0xD0) & 0x3F) | (self.c << 7) | (ov << 2))

    def push(self, v):
        self.sp = (self.sp + 1) & 0xFF
        self.iram[self.sp] = v & 0xFF

    def pop(self):
        v = self.iram[self.sp]
        self.sp = (self.sp - 1) & 0xFF
        return v

    # -- main step -----------------------------------------------------
    def step(self):
        op = self.fetch()
        lo, hi = op & 0x0F, op >> 4
        if lo == 1:  # ACALL/AJMP
            t = ((self.pc) & 0xF800) | ((op >> 5) << 8) | self.fetch()
            if op & 0x10:
                self.push(self.pc & 0xFF)
                self.push(self.pc >> 8)
                self.call_depth += 1
                self.calls.append((self.pc - 2, t))
                self.pc = t
            else:
                self.pc = t
            return
        if op == 0x02:
            self.pc = self.fetch16()
            return
        if op == 0x12:
            t = self.fetch16()
            self.push(self.pc & 0xFF)
            self.push(self.pc >> 8)
            self.call_depth += 1
            self.calls.append((self.pc - 3, t))
            self.pc = t
            return
        if op == 0x22:  # RET
            h = self.pop()
            l = self.pop()
            self.pc = h << 8 | l
            self.call_depth -= 1
            if self.call_depth < 0:
                self.halted = 'ret-top'
            return
        if op == 0x32:  # RETI
            h = self.pop()
            l = self.pop()
            self.pc = h << 8 | l
            self.call_depth -= 1
            if self.call_depth < 0:
                self.halted = 'reti-top'
            return
        if op == 0x01 or op == 0x81 if False else False:
            pass
        if op in (0x00,):
            return  # NOP
        if op == 0x03:
            self.acc = (self.acc >> 1) | (self.acc << 7) & 0xFF if False else ((self.acc >> 1) | (self.acc & 1) << 7)
            return
        if op == 0x13:
            carry_out = self.acc & 1
            self.acc = ((self.acc >> 1) | (self.c << 7)) & 0xFF
            self.c = carry_out
            return
        if op == 0x23:
            self.acc = ((self.acc << 1) & 0xFE) | (self.acc >> 7)
            return
        if op == 0x33:
            new = ((self.acc << 1) & 0xFE) | self.c
            self.c = self.acc >> 7
            self.acc = new & 0xFF
            return
        if op == 0xC4:
            self.acc = (self.acc >> 4) | (self.acc << 4) & 0xF0
            return
        if op == 0x04:
            self.acc = (self.acc + 1) & 0xFF
            return
        if op == 0x05:
            a = self.fetch()
            self.wr_iram(a, (self.rd_iram(a) + 1) & 0xFF)
            return
        if 0x06 <= op <= 0x07:  # INC @Ri
            i = self.r(op & 1)
            self.iram[i] = (self.iram[i] + 1) & 0xFF
            return
        if 0x08 <= op <= 0x0F:
            i = op & 7
            self.setr(i, (self.r(i) + 1) & 0xFF)
            return
        if op == 0x14:
            self.acc = (self.acc - 1) & 0xFF
            return
        if op == 0x15:
            a = self.fetch()
            self.wr_iram(a, (self.rd_iram(a) - 1) & 0xFF)
            return
        if 0x16 <= op <= 0x17:  # DEC @Ri
            i = self.r(op & 1)
            self.iram[i] = (self.iram[i] - 1) & 0xFF
            return
        if 0x18 <= op <= 0x1F:
            i = op & 7
            self.setr(i, (self.r(i) - 1) & 0xFF)
            return
        if op == 0xD4:  # DA A (rarely used)
            a = self.acc
            if (a & 0x0F) > 9 or False:
                a += 0x06
            if a > 0x9F:
                a += 0x60
                self.c = 1
            self.acc = a & 0xFF
            return
        if op == 0xE4:
            self.acc = 0
            return
        if op == 0xF4:
            self.acc = ~self.acc & 0xFF
            return
        if op == 0xA4:  # MUL AB
            p = self.acc * self.b
            self.acc = p & 0xFF
            self.b = p >> 8
            self.c = 0
            return
        if op == 0x84:  # DIV AB
            if self.b == 0:
                self.wr_iram(0xD0, self.rd_iram(0xD0) | 4)
            else:
                q, r = divmod(self.acc, self.b)
                self.acc, self.b = q, r
            self.c = 0
            return
        if op == 0x73:  # JMP @A+DPTR
            self.pc = (self.acc + self.dptr) & 0xFFFF
            return
        if op == 0x83:  # MOVC A,@A+PC
            self.acc = self.rd_code((self.acc + self.pc) & 0xFFFF)
            return
        if op == 0x93:  # MOVC A,@A+DPTR
            self.acc = self.rd_code((self.acc + self.dptr) & 0xFFFF)
            return
        if op == 0xE0:  # MOVX A,@DPTR
            if self.hw_override is not None and self.dptr >= 0xEF00:
                self.acc = self.hw_override & 0xFF
                self.io_reads.append((self.dptr, self.acc))
                return
            self.acc = self.xdata[self.dptr]
            self.io_reads.append((self.dptr, self.acc))
            return
        if op == 0xF0:  # MOVX @DPTR,A
            self.xdata[self.dptr] = self.acc
            self.io_writes.append((self.dptr, self.acc))
            return
        if op in (0xE2, 0xE3):  # MOVX A,@Ri
            self.acc = self.xdata[self.r(op & 1)]
            return
        if op in (0xF2, 0xF3):
            self.xdata[self.r(op & 1)] = self.acc
            return
        if op in (0xE6, 0xE7):  # MOV A,@Ri
            self.acc = self.iram[self.r(op & 1)]
            return
        if op in (0xF6, 0xF7):
            self.iram[self.r(op & 1)] = self.acc
            return
        # MOV A,# / MOV dir,# / MOV DPTR,#
        if op == 0x74:
            self.acc = self.fetch()
            return
        if op == 0x75:
            a = self.fetch()
            self.wr_iram(a, self.fetch())
            return
        if op == 0x90:
            self.dptr = self.fetch16()
            self.sfr[0x82], self.sfr[0x83] = self.dptr & 0xFF, self.dptr >> 8
            return
        if op == 0xA3:
            self.dptr = (self.dptr + 1) & 0xFFFF
            self.sfr[0x82], self.sfr[0x83] = self.dptr & 0xFF, self.dptr >> 8
            return
        # conditional jumps
        def rel():
            off = self.fetch()
            return (self.pc + (off - 256 if off > 127 else off)) & 0xFFFF

        if op == 0x40:
            t = rel()
            if self.c:
                self.pc = t
            return
        if op == 0x50:
            t = rel()
            if not self.c:
                self.pc = t
            return
        if op == 0x60:
            t = rel()
            if self.acc == 0:
                self.pc = t
            return
        if op == 0x70:
            t = rel()
            if self.acc:
                self.pc = t
            return
        if op == 0x80:
            t = rel()
            self.pc = t
            return
        if op in (0x20, 0x30):  # JB/JNB
            b = self.fetch()
            t = rel()
            v = self.rd_bit(b)
            if (op == 0x20 and v) or (op == 0x30 and not v):
                self.pc = t
            return
        if op == 0x10:  # JBC
            b = self.fetch()
            t = rel()
            a_, m = self.bitaddr(b)
            if self.rd_iram(a_) & m:
                self.wr_iram(a_, self.rd_iram(a_) & ~m)
                self.pc = t
            return
        if op in (0xB4, 0xB5):  # CJNE A,#/dir
            a = self.fetch()
            t = rel()
            other = a if op == 0xB4 else self.rd_iram(a)
            self.c = 0 if self.acc >= other else 1
            if self.acc != other:
                self.pc = t
            return
        if op in (0xB6, 0xB7):  # CJNE @Ri,#imm,rel
            a = self.fetch()
            t = rel()
            src = self.iram[self.r(op & 1)]
            self.c = 0 if src >= a else 1
            if src != a:
                self.pc = t
            return
        if op in (0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF):  # CJNE Rn,#imm,rel
            a = self.fetch()
            t = rel()
            src = self.r(op & 7)
            self.c = 0 if src >= a else 1
            if src != a:
                self.pc = t
            return
        if op == 0xD5:  # DJNZ dir
            a = self.fetch()
            t = rel()
            v = (self.rd_iram(a) - 1) & 0xFF
            self.wr_iram(a, v)
            if v:
                self.pc = t
            return
        if 0xD8 <= op <= 0xDF:  # DJNZ Rn
            t = rel()
            i = op & 7
            v = (self.r(i) - 1) & 0xFF
            self.setr(i, v)
            if v:
                self.pc = t
            return
        # arithmetic
        if op == 0x24:
            self.add(self.fetch())
            return
        if op == 0x25:
            self.add(self.rd_iram(self.fetch()))
            return
        if op in (0x26, 0x27):
            self.add(self.iram[self.r(op & 1)])
            return
        if op == 0x34:
            self.add(self.fetch(), self.c)
            return
        if op == 0x35:
            self.add(self.rd_iram(self.fetch()), self.c)
            return
        if op in (0x36, 0x37):
            self.add(self.iram[self.r(op & 1)], self.c)
            return
        if 0x28 <= op <= 0x2F:  # ADD A,Rn
            self.add(self.r(op & 7))
            return
        if op in (0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F):
            self.add(self.r(op & 7))
            return
        if op in (0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F):
            self.subb(self.r(op & 7))
            return
        if op == 0x94:
            self.subb(self.fetch())
            return
        if op == 0x95:
            self.subb(self.rd_iram(self.fetch()))
            return
        if op in (0x96, 0x97):
            self.subb(self.iram[self.r(op & 1)])
            return
        # logic
        if op == 0x42:
            a = self.fetch()
            self.wr_iram(a, self.rd_iram(a) | self.acc)
            return
        if op == 0x43:
            a = self.fetch()
            self.wr_iram(a, self.rd_iram(a) | self.fetch())
            return
        if op == 0x44:
            self.acc |= self.fetch()
            return
        if op == 0x45:
            self.acc |= self.rd_iram(self.fetch())
            return
        if op in (0x46, 0x47):
            self.acc |= self.iram[self.r(op & 1)]
            return
        if op in (0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F):
            self.acc |= self.r(op & 7)
            return
        if op == 0x52:
            a = self.fetch()
            self.wr_iram(a, self.rd_iram(a) & self.acc)
            return
        if op == 0x53:
            a = self.fetch()
            self.wr_iram(a, self.rd_iram(a) & self.fetch())
            return
        if op == 0x54:
            self.acc &= self.fetch()
            return
        if op == 0x55:
            self.acc &= self.rd_iram(self.fetch())
            return
        if op in (0x56, 0x57):
            self.acc &= self.iram[self.r(op & 1)]
            return
        if op in (0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F):
            self.acc &= self.r(op & 7)
            return
        if op == 0x62:
            a = self.fetch()
            self.wr_iram(a, self.rd_iram(a) ^ self.acc)
            return
        if op == 0x63:
            a = self.fetch()
            self.wr_iram(a, self.rd_iram(a) ^ self.fetch())
            return
        if op == 0x64:
            self.acc ^= self.fetch()
            return
        if op == 0x65:
            self.acc ^= self.rd_iram(self.fetch())
            return
        if op in (0x66, 0x67):
            self.acc ^= self.iram[self.r(op & 1)]
            return
        if op in (0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F):
            self.acc ^= self.r(op & 7)
            return
        # moves
        if op == 0xE5:
            self.acc = self.rd_iram(self.fetch())
            return
        if op == 0xF5:
            self.wr_iram(self.fetch(), self.acc)
            return
        if op == 0x85:
            src = self.fetch()
            dst = self.fetch()
            self.wr_iram(dst, self.rd_iram(src))
            return
        if op in (0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF):
            self.setr(op & 7, self.rd_iram(self.fetch()))
            return
        if op in (0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F):
            self.wr_iram(self.fetch(), self.r(op & 7))
            return
        if op in (0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F):
            self.setr(op & 7, self.fetch())
            return
        if op in (0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF):
            self.acc = self.r(op & 7)
            return
        if op in (0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF):
            self.setr(op & 7, self.acc)
            return
        if op in (0xA6, 0xA7):  # MOV @Ri,dir
            self.iram[self.r(op & 1)] = self.rd_iram(self.fetch())
            return
        if op in (0xA6 + 1,):
            return
        if op in (0x76, 0x77):  # MOV @Ri,#imm
            self.iram[self.r(op & 1)] = self.fetch()
            return
        if op == 0xC0:
            self.push(self.rd_iram(self.fetch()))
            return
        if op == 0xD0:
            self.wr_iram(self.fetch(), self.pop())
            return
        if op in (0xC5,):
            a = self.fetch()
            self.acc, v = self.rd_iram(a), self.acc
            self.wr_iram(a, v)
            return
        if op in (0xC6, 0xC7):
            i = self.r(op & 1)
            self.acc, self.iram[i] = self.iram[i], self.acc
            return
        if op in (0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF):
            i = op & 7
            self.acc, v = self.r(i), self.acc
            self.setr(i, v)
            return
        if op in (0xD6, 0xD7):  # XCHD
            i = self.r(op & 1)
            lo_a, lo_i = self.acc & 0xF, self.iram[i] & 0xF
            self.acc = (self.acc & 0xF0) | lo_i
            self.iram[i] = (self.iram[i] & 0xF0) | lo_a
            return
        # bit ops
        if op == 0xC3:
            self.c = 0
            return
        if op == 0xD3:
            self.c = 1
            return
        if op == 0xB3:
            self.c ^= 1
            return
        if op == 0xA2:
            self.c = self.rd_bit(self.fetch())
            return
        if op == 0x92:
            self.wr_bit(self.fetch(), self.c)
            return
        if op == 0x72:  # ORL C,bit
            self.c |= self.rd_bit(self.fetch())
            return
        if op == 0x82:  # ANL C,bit
            self.c &= self.rd_bit(self.fetch())
            return
        if op == 0xA0:  # ORL C,/bit
            self.c |= 1 - self.rd_bit(self.fetch())
            return
        if op == 0xB0:  # ANL C,/bit
            self.c &= 1 - self.rd_bit(self.fetch())
            return
        if op in (0xB2,):
            b = self.fetch()
            self.wr_bit(b, 1 - self.rd_bit(b))
            return
        if op in (0xC2,):
            self.wr_bit(self.fetch(), 0)
            return
        if op in (0xD2,):
            self.wr_bit(self.fetch(), 1)
            return
        raise RuntimeError(f'unimplemented opcode {op:02X} at {self.pc-1:04X}')

    def run(self, pc, regs=None, args=None):
        self.pc = pc
        self.call_depth = 0
        for k, v in (regs or {}).items():
            self.setr(int(k[1]), v)
        while not self.halted and self.steps < self.max_steps:
            self.steps += 1
            self.step()
        return self


def run(pc, regs=None, xdata=None, iram=None, max_steps=2_000_000, trace_calls=False):
    m = Machine(max_steps=max_steps)
    for a, v in (xdata or {}).items():
        if isinstance(v, int):
            m.xdata[a] = v
        else:
            m.xdata[a:a + len(v)] = v
    for a, v in (iram or {}).items():
        m.wr_iram(a, v)
    m.run(pc, regs=regs)
    return m


def rd32(m, a):
    return int.from_bytes(m.xdata[a:a + 4], 'big')


def rd16(m, a):
    return int.from_bytes(m.xdata[a:a + 2], 'big')
