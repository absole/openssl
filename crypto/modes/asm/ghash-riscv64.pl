#! /usr/bin/env perl
# Copyright 2022 The OpenSSL Project Authors. All Rights Reserved.
#
# Licensed under the Apache License 2.0 (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin";
use lib "$Bin/../../perlasm";
use riscv;

# $output is the last argument if it looks like a file (it has an extension)
# $flavour is the first argument if it doesn't look like a file
my $output = $#ARGV >= 0 && $ARGV[$#ARGV] =~ m|\.\w+$| ? pop : undef;
my $flavour = $#ARGV >= 0 && $ARGV[0] !~ m|\.| ? shift : undef;

$output and open STDOUT,">$output";

my $code=<<___;
.text
___

################################################################################
# void gcm_init_rv64i_zbc(u128 Htable[16], const u64 H[2]);
# void gcm_init_rv64i_zbc__zbb(u128 Htable[16], const u64 H[2]);
# void gcm_init_rv64i_zbc__zbkb(u128 Htable[16], const u64 H[2]);
#
# input:  H: 128-bit H - secret parameter E(K, 0^128)
# output: Htable: Preprocessed key data for gcm_gmult_rv64i_zbc* and
#                 gcm_ghash_rv64i_zbc*
#
# All callers of this function revert the byte-order unconditionally
# on little-endian machines. So we need to revert the byte-order back.
# Additionally we reverse the bits of each byte.

{
my ($Htable,$H,$VAL0,$VAL1,$TMP0,$TMP1,$TMP2) = ("a0","a1","a2","a3","t0","t1","t2");

$code .= <<___;
.p2align 3
.globl gcm_init_rv64i_zbc
.type gcm_init_rv64i_zbc,\@function
gcm_init_rv64i_zbc:
    ld      $VAL0,0($H)
    ld      $VAL1,8($H)
    @{[brev8_rv64i   $VAL0, $TMP0, $TMP1, $TMP2]}
    @{[brev8_rv64i   $VAL1, $TMP0, $TMP1, $TMP2]}
    @{[sd_rev8_rv64i $VAL0, $Htable, 0, $TMP0]}
    @{[sd_rev8_rv64i $VAL1, $Htable, 8, $TMP0]}
    ret
.size gcm_init_rv64i_zbc,.-gcm_init_rv64i_zbc
___
}

{
my ($Htable,$H,$VAL0,$VAL1,$TMP0,$TMP1,$TMP2) = ("a0","a1","a2","a3","t0","t1","t2");

$code .= <<___;
.p2align 3
.globl gcm_init_rv64i_zbc__zbb
.type gcm_init_rv64i_zbc__zbb,\@function
gcm_init_rv64i_zbc__zbb:
    ld      $VAL0,0($H)
    ld      $VAL1,8($H)
    @{[brev8_rv64i $VAL0, $TMP0, $TMP1, $TMP2]}
    @{[brev8_rv64i $VAL1, $TMP0, $TMP1, $TMP2]}
    @{[rev8 $VAL0, $VAL0]}
    @{[rev8 $VAL1, $VAL1]}
    sd      $VAL0,0($Htable)
    sd      $VAL1,8($Htable)
    ret
.size gcm_init_rv64i_zbc__zbb,.-gcm_init_rv64i_zbc__zbb
___
}

{
my ($Htable,$H,$TMP0,$TMP1) = ("a0","a1","t0","t1");

$code .= <<___;
.p2align 3
.globl gcm_init_rv64i_zbc__zbkb
.type gcm_init_rv64i_zbc__zbkb,\@function
gcm_init_rv64i_zbc__zbkb:
    ld      $TMP0,0($H)
    ld      $TMP1,8($H)
    @{[brev8 $TMP0, $TMP0]}
    @{[brev8 $TMP1, $TMP1]}
    @{[rev8 $TMP0, $TMP0]}
    @{[rev8 $TMP1, $TMP1]}
    sd      $TMP0,0($Htable)
    sd      $TMP1,8($Htable)
    ret
.size gcm_init_rv64i_zbc__zbkb,.-gcm_init_rv64i_zbc__zbkb
___
}

################################################################################
# void gcm_gmult_rv64i_zbc(u64 Xi[2], const u128 Htable[16]);
# void gcm_gmult_rv64i_zbc__zbkb(u64 Xi[2], const u128 Htable[16]);
#
# input:  Xi: current hash value
#         Htable: copy of H
# output: Xi: next hash value Xi
#
# Compute GMULT (Xi*H mod f) using the Zbc (clmul) and Zbb (basic bit manip)
# extensions. Using the no-Karatsuba approach and clmul for the final reduction.
# This results in an implementation with minimized number of instructions.
# HW with clmul latencies higher than 2 cycles might observe a performance
# improvement with Karatsuba. HW with clmul latencies higher than 6 cycles
# might observe a performance improvement with additionally converting the
# reduction to shift&xor. For a full discussion of this estimates see
# https://github.com/riscv/riscv-crypto/blob/master/doc/supp/gcm-mode-cmul.adoc
{
my ($Xi,$Htable,$x0,$x1,$y0,$y1) = ("a0","a1","a4","a5","a6","a7");
my ($z0,$z1,$z2,$z3,$t0,$t1,$polymod) = ("t0","t1","t2","t3","t4","t5","t6");

$code .= <<___;
.p2align 3
.globl gcm_gmult_rv64i_zbc
.type gcm_gmult_rv64i_zbc,\@function
gcm_gmult_rv64i_zbc:
    # Load Xi and bit-reverse it
    ld        $x0, 0($Xi)
    ld        $x1, 8($Xi)
    @{[brev8_rv64i $x0, $z0, $z1, $z2]}
    @{[brev8_rv64i $x1, $z0, $z1, $z2]}

    # Load the key (already bit-reversed)
    ld        $y0, 0($Htable)
    ld        $y1, 8($Htable)

    # Load the reduction constant
    la        $polymod, Lpolymod
    lbu       $polymod, 0($polymod)

    # Multiplication (without Karatsuba)
    @{[clmulh $z3, $x1, $y1]}
    @{[clmul  $z2, $x1, $y1]}
    @{[clmulh $t1, $x0, $y1]}
    @{[clmul  $z1, $x0, $y1]}
    xor       $z2, $z2, $t1
    @{[clmulh $t1, $x1, $y0]}
    @{[clmul  $t0, $x1, $y0]}
    xor       $z2, $z2, $t1
    xor       $z1, $z1, $t0
    @{[clmulh $t1, $x0, $y0]}
    @{[clmul  $z0, $x0, $y0]}
    xor       $z1, $z1, $t1

    # Reduction with clmul
    @{[clmulh $t1, $z3, $polymod]}
    @{[clmul  $t0, $z3, $polymod]}
    xor       $z2, $z2, $t1
    xor       $z1, $z1, $t0
    @{[clmulh $t1, $z2, $polymod]}
    @{[clmul  $t0, $z2, $polymod]}
    xor       $x1, $z1, $t1
    xor       $x0, $z0, $t0

    # Bit-reverse Xi back and store it
    @{[brev8_rv64i $x0, $z0, $z1, $z2]}
    @{[brev8_rv64i $x1, $z0, $z1, $z2]}
    sd        $x0, 0($Xi)
    sd        $x1, 8($Xi)
    ret
.size gcm_gmult_rv64i_zbc,.-gcm_gmult_rv64i_zbc
___
}

{
my ($Xi,$Htable,$x0,$x1,$y0,$y1) = ("a0","a1","a4","a5","a6","a7");
my ($z0,$z1,$z2,$z3,$t0,$t1,$polymod) = ("t0","t1","t2","t3","t4","t5","t6");

$code .= <<___;
.p2align 3
.globl gcm_gmult_rv64i_zbc__zbkb
.type gcm_gmult_rv64i_zbc__zbkb,\@function
gcm_gmult_rv64i_zbc__zbkb:
    # Load Xi and bit-reverse it
    ld        $x0, 0($Xi)
    ld        $x1, 8($Xi)
    @{[brev8  $x0, $x0]}
    @{[brev8  $x1, $x1]}

    # Load the key (already bit-reversed)
    ld        $y0, 0($Htable)
    ld        $y1, 8($Htable)

    # Load the reduction constant
    la        $polymod, Lpolymod
    lbu       $polymod, 0($polymod)

    # Multiplication (without Karatsuba)
    @{[clmulh $z3, $x1, $y1]}
    @{[clmul  $z2, $x1, $y1]}
    @{[clmulh $t1, $x0, $y1]}
    @{[clmul  $z1, $x0, $y1]}
    xor       $z2, $z2, $t1
    @{[clmulh $t1, $x1, $y0]}
    @{[clmul  $t0, $x1, $y0]}
    xor       $z2, $z2, $t1
    xor       $z1, $z1, $t0
    @{[clmulh $t1, $x0, $y0]}
    @{[clmul  $z0, $x0, $y0]}
    xor       $z1, $z1, $t1

    # Reduction with clmul
    @{[clmulh $t1, $z3, $polymod]}
    @{[clmul  $t0, $z3, $polymod]}
    xor       $z2, $z2, $t1
    xor       $z1, $z1, $t0
    @{[clmulh $t1, $z2, $polymod]}
    @{[clmul  $t0, $z2, $polymod]}
    xor       $x1, $z1, $t1
    xor       $x0, $z0, $t0

    # Bit-reverse Xi back and store it
    @{[brev8  $x0, $x0]}
    @{[brev8  $x1, $x1]}
    sd        $x0, 0($Xi)
    sd        $x1, 8($Xi)
    ret
.size gcm_gmult_rv64i_zbc__zbkb,.-gcm_gmult_rv64i_zbc__zbkb
___
}

$code .= <<___;
.p2align 3
Lbrev8_const:
    .dword  0xAAAAAAAAAAAAAAAA
    .dword  0xCCCCCCCCCCCCCCCC
    .dword  0xF0F0F0F0F0F0F0F0
.size Lbrev8_const,.-Lbrev8_const

Lpolymod:
    .byte 0x87
.size Lpolymod,.-Lpolymod
___

print $code;

close STDOUT or die "error closing STDOUT: $!";
