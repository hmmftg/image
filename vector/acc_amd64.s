// Copyright 2016 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// +build !appengine
// +build gc
// +build !noasm

#include "textflag.h"

// fl is short for floating point math. fx is short for fixed point math.

DATA flAlmost256<>+0x00(SB)/8, $0x437fffff437fffff
DATA flAlmost256<>+0x08(SB)/8, $0x437fffff437fffff
DATA flOnes<>+0x00(SB)/8, $0x3f8000003f800000
DATA flOnes<>+0x08(SB)/8, $0x3f8000003f800000
DATA flSignMask<>+0x00(SB)/8, $0x7fffffff7fffffff
DATA flSignMask<>+0x08(SB)/8, $0x7fffffff7fffffff
DATA shuffleMask<>+0x00(SB)/8, $0x0c0804000c080400
DATA shuffleMask<>+0x08(SB)/8, $0x0c0804000c080400
DATA fxAlmost256<>+0x00(SB)/8, $0x000000ff000000ff
DATA fxAlmost256<>+0x08(SB)/8, $0x000000ff000000ff

GLOBL flAlmost256<>(SB), (NOPTR+RODATA), $16
GLOBL flOnes<>(SB), (NOPTR+RODATA), $16
GLOBL flSignMask<>(SB), (NOPTR+RODATA), $16
GLOBL shuffleMask<>(SB), (NOPTR+RODATA), $16
GLOBL fxAlmost256<>(SB), (NOPTR+RODATA), $16

// func haveSSE4_1() bool
TEXT ·haveSSE4_1(SB), NOSPLIT, $0
	MOVQ $1, AX
	CPUID
	SHRQ $19, CX
	ANDQ $1, CX
	MOVB CX, ret+0(FP)
	RET

// ----------------------------------------------------------------------------

// func fixedAccumulateOpSrcSIMD(dst []uint8, src []uint32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	-
//	xmm4	-
//	xmm5	fxAlmost256
//	xmm6	shuffleMask
//	xmm7	offset
TEXT ·fixedAccumulateOpSrcSIMD(SB), NOSPLIT, $0-48
	MOVQ dst_base+0(FP), DI
	MOVQ dst_len+8(FP), BX
	MOVQ src_base+24(FP), SI
	MOVQ src_len+32(FP), CX

	// Sanity check that len(dst) >= len(src).
	CMPQ BX, CX
	JLT  fxAccOpSrcEnd

	// CX = len(src) &^ 3
	// DX = len(src)
	MOVQ CX, DX
	ANDQ $-4, CX

	// fxAlmost256 := XMM(0x000000ff repeated four times) // Maximum of an uint8.
	// shuffleMask := XMM(0x0c080400 repeated four times) // PSHUFB shuffle mask.
	// offset      := XMM(0x00000000 repeated four times) // Cumulative sum.
	MOVOU fxAlmost256<>(SB), X5
	MOVOU shuffleMask<>(SB), X6
	XORPS X7, X7

	// i := 0
	MOVQ $0, AX

fxAccOpSrcLoop4:
	// for i < (len(src) &^ 3)
	CMPQ AX, CX
	JAE  fxAccOpSrcLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	PADDD X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	PADDD  X0, X1

	// x += offset
	PADDD X7, X1

	// y = abs(x)
	// y >>= 12 // Shift by 2*ϕ - 8.
	// y = min(y, fxAlmost256)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0xc,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x0c
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// z = shuffleTheLowBytesOfEach4ByteElement(y)
	// copy(dst[:4], low4BytesOf(z))
	PSHUFB X6, X2
	MOVL   X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, AX
	ADDQ $4, DI
	ADDQ $16, SI
	JMP  fxAccOpSrcLoop4

fxAccOpSrcLoop1:
	// for i < len(src)
	CMPQ AX, DX
	JAE  fxAccOpSrcEnd

	// x = src[i] + offset
	MOVL  (SI), X1
	PADDD X7, X1

	// y = abs(x)
	// y >>= 12 // Shift by 2*ϕ - 8.
	// y = min(y, fxAlmost256)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0xc,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x0c
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// dst[0] = uint8(y)
	MOVL X2, BX
	MOVB BX, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, AX
	ADDQ $1, DI
	ADDQ $4, SI
	JMP  fxAccOpSrcLoop1

fxAccOpSrcEnd:
	RET

// ----------------------------------------------------------------------------

// func floatingAccumulateOpSrcSIMD(dst []uint8, src []float32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	flAlmost256
//	xmm4	flOnes
//	xmm5	flSignMask
//	xmm6	shuffleMask
//	xmm7	offset
TEXT ·floatingAccumulateOpSrcSIMD(SB), NOSPLIT, $8-48
	MOVQ dst_base+0(FP), DI
	MOVQ dst_len+8(FP), BX
	MOVQ src_base+24(FP), SI
	MOVQ src_len+32(FP), CX

	// Sanity check that len(dst) >= len(src).
	CMPQ BX, CX
	JLT  flAccOpSrcEnd

	// CX = len(src) &^ 3
	// DX = len(src)
	MOVQ CX, DX
	ANDQ $-4, CX

	// Set MXCSR bits 13 and 14, so that the CVTPS2PL below is "Round To Zero".
	STMXCSR mxcsrOrig-8(SP)
	MOVL    mxcsrOrig-8(SP), AX
	ORL     $0x6000, AX
	MOVL    AX, mxcsrNew-4(SP)
	LDMXCSR mxcsrNew-4(SP)

	// flAlmost256 := XMM(0x437fffff repeated four times) // 255.99998 as a float32.
	// flOnes      := XMM(0x3f800000 repeated four times) // 1 as a float32.
	// flSignMask  := XMM(0x7fffffff repeated four times) // All but the sign bit of a float32.
	// shuffleMask := XMM(0x0c080400 repeated four times) // PSHUFB shuffle mask.
	// offset      := XMM(0x00000000 repeated four times) // Cumulative sum.
	MOVOU flAlmost256<>(SB), X3
	MOVOU flOnes<>(SB), X4
	MOVOU flSignMask<>(SB), X5
	MOVOU shuffleMask<>(SB), X6
	XORPS X7, X7

	// i := 0
	MOVQ $0, AX

flAccOpSrcLoop4:
	// for i < (len(src) &^ 3)
	CMPQ AX, CX
	JAE  flAccOpSrcLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	ADDPS X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	ADDPS  X0, X1

	// x += offset
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOnes)
	// y = mul(y, flAlmost256)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = float32ToInt32(y)
	// z = shuffleTheLowBytesOfEach4ByteElement(z)
	// copy(dst[:4], low4BytesOf(z))
	CVTPS2PL X2, X2
	PSHUFB   X6, X2
	MOVL     X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, AX
	ADDQ $4, DI
	ADDQ $16, SI
	JMP  flAccOpSrcLoop4

flAccOpSrcLoop1:
	// for i < len(src)
	CMPQ AX, DX
	JAE  flAccOpSrcRestoreMXCSR

	// x = src[i] + offset
	MOVL  (SI), X1
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOnes)
	// y = mul(y, flAlmost256)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = float32ToInt32(y)
	// dst[0] = uint8(z)
	CVTPS2PL X2, X2
	MOVL     X2, BX
	MOVB     BX, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, AX
	ADDQ $1, DI
	ADDQ $4, SI
	JMP  flAccOpSrcLoop1

flAccOpSrcRestoreMXCSR:
	LDMXCSR mxcsrOrig-8(SP)

flAccOpSrcEnd:
	RET